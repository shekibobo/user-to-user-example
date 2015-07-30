## Accessing Join-Model MetaData on `has_many :through` Associations in Rails

I mentioned [in my previous blog post](/README.md) I want to know information about a match between users when I'm looking at them, such as how long they've been considered a match. There are a few ways of doing this. The hard way is to always look up the match for two users:

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
