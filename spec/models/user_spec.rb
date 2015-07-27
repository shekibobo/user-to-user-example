require 'rails_helper'

RSpec.describe User, type: :model do
  describe '#matched_users' do
    context 'when adding users' do
      let(:parent) { create(:user) }
      let(:child) { create(:user) }

      it "adds a child to the parent's matched_users collection" do
        expect(parent.matched_users).to be_empty
        parent.matched_users.replace [child]
        expect(parent.reload.matched_users).to match_array [child]
      end

      it "adds parent to the child's matched_users collection" do
        expect(child.matched_users).to be_empty
        parent.matched_users.replace [child]
        expect(child.reload.matched_users).to match_array [parent]
      end

      it "doesn't add matched_user to the parent if it exists already" do
        parent.matched_users.replace [child]
        parent.matched_users << child
        expect(parent.reload.matched_users).to match_array [child]
      end

      it "doesn't add matched_user to the child if it exists already" do
        parent.matched_users.replace [child]
        parent.matched_users << child
        expect(child.reload.matched_users).to match_array [parent]
      end
    end

    context 'when removing users' do
      let(:parent) { create(:user, matched_users: [child]) }
      let(:child) { create(:user) }

      it "removes the child from the parent's matched_users collection" do
        expect(parent.matched_users).to eq [child]
        parent.matched_users.replace []
        expect(parent.reload.matched_users).to be_empty
      end

      it "removes parent from the child's matched_users collection" do
        expect(child.matched_users).to eq [parent]
        parent.matched_users.replace []
        expect(child.reload.matched_users).to be_empty
      end
    end

    describe '.with_match_data' do
      let!(:parent) { create(:user) }
      let!(:child) { create(:user) }
      let!(:match) { create(:match, user: parent, matched_user: child, created_at: 3.days.ago) }

      let(:matched_users) { parent.matched_users.with_match_data }

      describe '#match_created_at' do
        it 'provides access to match_created_at' do
          expect(matched_users.first.match_created_at)
            .to be_within(1).of(match.created_at)
        end

        it 'is a timestamp object' do
          expect(matched_users.first.match_created_at).to be_a(match.created_at.class)
        end

        it 'is nil on a user pulled from a different query' do
          expect(User.find(child.id).match_created_at).to be_nil
        end

        it 'can still be chained with other queries' do
          expect(matched_users.with_match_data.count).to eq 1
        end
      end
    end
  end
end
