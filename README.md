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
  has_many :matched_users, through: :matches, class_name: "User"
end
```

At this point, we'll have two passing tests (where we assert the child is added or removed from the parent's collection) and two failing tests (where the parent is added or removed from the child's collection). So cool, we're half way there.

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

Keep in mind here that on a `has_many :through` association, when `destroy` or `delete` methods are called, it will always delete the *link* between the two models, not the models themselves. By adding `dependent: :destroy`, we are telling ActiveRecord that we want to make sure callbacks are called whenever we remove an item from the collection. Running the tests will show that we've successfully passed all of our original specs for the bi-directional, self-referential association.

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

## Count

If we dig a little bit deeper, we will find out that calling `users.matched_users.with_match_data.count` will actually result in an `ActiveRecord::StatementInvalid` error:

```ruby
[14] pry(main)> p.reload.matched_users.with_match_data.count
  User Load (0.1ms)  SELECT  "users".* FROM "users" WHERE "users"."id" = ? LIMIT 1  [["id", 1]]
   (1.3ms)  SELECT DISTINCT COUNT(DISTINCT users.*, matches.created_at AS match_created_at) FROM "users" INNER JOIN "matches" ON "users"."id" = "matches"."matched_user_id" WHERE "matches"."user_id" = ?  [["user_id", 1]]
SQLite3::SQLException: near "*": syntax error: SELECT DISTINCT COUNT(DISTINCT users.*, matches.created_at AS match_created_at) FROM "users" INNER JOIN "matches" ON "users"."id" = "matches"."matched_user_id" WHERE "matches"."user_id" = ?
ActiveRecord::StatementInvalid: SQLite3::SQLException: near "*": syntax error: SELECT DISTINCT COUNT(DISTINCT users.*, matches.created_at AS match_created_at) FROM "users" INNER JOIN "matches" ON "users"."id" = "matches"."matched_user_id" WHERE "matches"."user_id" = ?
```

That's a little weird, because `.size` works just fine:

```ruby
[12] pry(main)> p.matched_users.with_match_data.size
   (0.2ms)  SELECT DISTINCT COUNT(DISTINCT "users"."id") FROM "users" INNER JOIN "matches" ON "users"."id" = "matches"."matched_user_id" WHERE "matches"."user_id" = ?  [["user_id", 1]]
```

But you'll notice that the problem arises because of the `select` statement we modify manually when we include `with_match_data` in the query. And this seems like it would be enough of an issue that we can't just include match data by default. But why does `size` work, but `count` doesn't? Let's take a look at the source.

From [ActiveRecord::Relation::Calculations](https://github.com/rails/rails/blob/master/activerecord/lib/active_record/relation/calculations.rb):

```ruby
# Note: not all valid +select+ expressions are valid +count+ expressions. The specifics differ
# between databases. In invalid cases, an error from the database is thrown.
def count(column_name = nil)
  calculate(:count, column_name)
end
```

Well, it says it right there: we might get a problem with our `select` expression. But why does `size` work? Let's see.

From [ActiveRecord::Relation](https://github.com/rails/rails/blob/master/activerecord/lib/active_record/relation.rb):

```ruby
# Returns size of the records.
def size
  loaded? ? @records.length : count(:all)
end
```

And there is the culprit. By default `size` calls `count` with `:all`, which is an alias for `*` if you dig into the docs. So how do we solve this? Lets write a test:


```ruby
# users_spec.rb
RSpec.describe User, type: :model do
  describe '#matched_users' do
    # ...
    describe '.with_match_data' do
      # Same setup as the rest of them

      describe '#match_created_at' do
        it 'provides access to match_created_at'
        it 'is a timestamp object'
        it 'is nil on a user pulled from a different query'

        it 'can still be counted' do
          expect(matched_users.with_match_data.count).to eq 1
        end
      end
    end
  end
end
```

If we run this, we'll see it fail for the same reason we saw above. Let's fix it:

```ruby
class User < ActiveRecord::Base
  has_many :matches
  has_many :matched_users, -> { uniq }, through: :matches, class_name: 'User', dependent: :destroy do
    def with_match_data
      select('users.*, matches.created_at AS match_created_at')
    end

    def count(column_name = :all)
      super
    end
  end
end
```

Now we should have a pretty robust solution to our bi-directional, self-referential, many-to-many association. Now we can use our complex algorithm to assign the memberships when appropriate, and we only need to run them from one side and the other side will be updated:

```ruby
current_user.matched_users.replace MatchMaker.matches_for(current_user) if current_user.matches_outdated?
```

We can now be confident that running this will have the following effects:

- `current_user.matched_users` get updated with all their matches
- each of the `current_user`'s matches now have `current_user` in them
- each of the users who were removed from `current_user`'s matches no longer have `current_user` in them

This is going to be a fairly reliable way of keeping our users' matches up to date without the costly overhead of actually running the algorithm every time our users want to see their matches.
