Bi-Directional and Self-Referential Associations in Rails
============

Lately, I've been working on an application that works to match users together based on some kind of complex criteria (read: big slow database query: BSDBQ). I'm not going to go into the complexities of the algorithm here, since it doesn't really matter. What does matter is that I can't just use that query when I want to find user matches because I also need historical information about the match. For instance, I want to know how long these users have been considered a match.

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

    context "when removing users" do
      let(:parent) { create(:user, matched_users: [child]) }
      let(:child) { create(:user, matched_users: [parent]) }

      it "removes the child from the parent's matched_users collection" do
        expect(parent.matched_users).to match_array [child]
        parent.matched_users.replace []
        expect(parent.reload.matched_users).to be_empty
      end

      it "removes parent from the child's matched_users collection" do
        expect(child.matched_users).to match_array [parent]
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
  has_many :matched_users, -> { uniq }, through: :matches, class_name: "User"
end
```

At this point, we'll have four passing tests (where we assert the child is added or removed from the parent's collection) and two failing tests (where the parent is added or removed from the child's collection). So cool, we're half way there.

Next we'll need to add callbacks to the `Match` model to automatically set up an inverse `match` object for each new match that's created, but only if one doesn't already exist yet:

```ruby
class Match < ActiveRecord::Base
  belongs_to :user
  belongs_to :matched_user, class_name: "User"

  after_create :create_inverse, unless: :has_inverse?

  def create_inverse
    Match.create(matched_user_id: user_id, user_id: matched_user_id)
  end

  def has_inverse?
    Match.exists?(matched_user_id: user_id, user_id: matched_user_id)
  end
end
```

Now we just need to make sure any inverse matches are destroyed if we remove a child from the parent:

```ruby
class Match < ActiveRecord::Base
  belongs_to :user
  belongs_to :matched_user, class_name: "User"

  after_create :create_inverse, unless: :has_inverse?
  after_destroy :destroy_inverses, if: :has_inverse?

  def create_inverse
    self.class.create(inverse_match_options)
  end

  def destroy_inverses
    inverses.destroy_all
  end

  def has_inverse?
    self.class.exists?(inverse_match_options)
  end

  def inverses
    self.class.where(inverse_match_options)
  end

  def inverse_match_options
    { matched_user_id: user_id, user_id: matched_user_id }
  end
end
```

Awesome, nice and DRY. But wait. Our last test still doesn't pass, because the parent still belongs to the child after the child is removed from the parent. [Here's why](http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#module-ActiveRecord::Associations::ClassMethods-label-Delete+or+destroy-3F):

> For has_many, destroy and destroy_all will always call the destroy method of the record(s) being removed so that callbacks are run. However delete and delete_all will either do the deletion according to the strategy specified by the :dependent option, or if no :dependent option is given, then it will follow the default strategy. The default strategy is to do nothing (leave the foreign keys with the parent ids set), *except for has_many :through, where the default strategy is delete_all (delete the join records, without running their callbacks)*.

So in order to make sure we maintain the bi-directional integrity of the association, we need to change the deletion strategy on the `User#has_many` association.

```ruby
class User < ActiveRecord::Base
  has_many :matches
  has_many :matched_users, -> { uniq },
           through: :matches,
           class_name: 'User',
           dependent: :destroy # make sure callbacks are run on matches
end
```

Keep in mind here that on a `has_many` association, when `destroy` or `delete` methods are called, it will always delete the *link* between the two models, not the models themselves. By adding `dependent: :destroy`, we are telling ActiveRecord that we want to make sure callbacks are called whenever we remove an item from the collection. Running the tests will show that we've successfully passed all of our original specs for the bi-directional, self-referential association.

## Extra Credit

I mentioned earlier that I want to know information about a match between users when I'm looking at them, such as how long they've been considered a match. There are a few ways of doing this. The hard way is to always look up the match for two users:

```ruby
class User < ActiveRecord::Base
  # ...

  def match_for(other)
    matches.where(matched_user_id: other.id)
  end
```

And this might be worth keeping around for convenience later on, but this is going to kill performance when we show a list of all 500 or so matches on the page. There is a slightly better way. We can modify our `select` query for the association, either directly or through an additional scope, in such a way that a virtual attribute `match_created_at` will be available on the user models obtained from the association. Let's try that out:

```ruby
describe User do
  describe "#matched_users" do
    context "when adding users" do; end
    context "when removing users" do; end

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
      end
    end
  end
end
```

We can provide a scope that will only be available for this association by [extending the association](http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#module-ActiveRecord::Associations::ClassMethods-label-Association+extensions):

```ruby
class User < ActiveRecord::Base
  has_many :matches
  has_many :matched_users, -> { uniq }, through: :matches, class_name: 'User', dependent: :destroy do
    def with_match_data
      select('users.*, matches.created_at AS match_created_at')
    end
  end
end
```

This will give us the attribute `User#match_created_at` from the record that joined the matched user to the current user. The only problem is that it comes back as a `String`. So in order to make it accessible with all the `DateTime`y goodness of a normal timestamp field, we'll add another method to parse it:

```ruby
class User < ActiveRecord::Base
  # ...

  def match_created_at
    Time.zone.parse(self[:match_created_at]) if self[:match_created_at]
  end
end
```

And there we have it. A self-referential, bi-directional many-to-many association with match metadata.
