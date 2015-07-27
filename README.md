Bidirectional `has_many :through` Associations in Rails
============

Lately, I've been working on an application that works to match users together based on some kind of complex criteria (read: big slow database query: BSDBQ). I'm not going to go into the complexities of the algorithm here, since it doesn't really matter. What does matter is that I can't just use that query when I want to find user matches because I also need historical information about said match. For instance, I want to know how long these users have been considered a match.

Furthermore, a match for one user also needs to be a match for the other user: `f(x) = y && f(y) = x`, and it always needs to stay in sync. If one user is no longer considered a match, the other user also shouldn't be considered a match.

So basically, we have a bidirectional self-referential association between users, where the association itself has metadata.

The solution for this is to use a `has_many :through` association with a join model. Let's take a look at how we get this started.

Let's start with a basic user model and a test:

```ruby
class User < ActiveRecord::Base
  # TODO: create association :matched_users
  # TODO: create reverse association :matched_users
end

describe User do
  describe "#matched_users" do
    context "when adding users" do
      let(:parent) { create(:user) }
      let(:child) { create(:user) }

      it "adds a child to the parent's matched_users collection" do
        expect(parent.matched_users).to be_empty
        parent.matched_users.replace [child]
        expect(parent.reload.matched_users).to eq [child]
      end

      it "adds parent to the child's matched_users collection" do
        expect(child.matched_users).to be_empty
        parent.matched_users.replace [child]
        expect(child.reload.matched_users).to eq [parent]
      end
    end

    context "when removing users" do
      let(:parent) { create(:user, matched_users: [child]) }
      let(:child) { create(:user, matched_users: [parent]) }

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
  end
end
```

Of course, this will fail, so lets create an association with a join model:

```ruby
class CreateMatches < ActiveRecord::Migration
  def change
    create_table :matches do |t|
      t.references :user, index: true, foreign_key: true
      t.references :matched_user, index: true
      t.timestamps
    end
    add_foreign_key :matches, :users, column: :matched_user_id
  end
end

class Match < ActiveRecord::Base
  belongs_to :user
  belongs_to :matched_user, class_name: "User"
end

class User < ActiveRecord::Base
  has_many :matches
  has_many :matched_users, through: :matches, class_name: "User"
end
```
