Bi-Directional and Self-Referential Associations in Rails
============

I've been working on an application that works to match users together based on a complex set of criteria (read: big slow database query and in-memory processing). The core usage of the application revolves around these user matches, so I want to make sure that either the algorithm will run very fast or can be cached so that it's not run every time a user visits their matches page.

The most important requirement for our matches is that a match for one user also needs to be a match for the other user. Formally, `∀ x,y ∈ Users: f(x) ∋ y -> f(y) ∋ x`: for all `users` `x` and `y`, if `matched_users` belonging to `x` contains `y`, then `matched_users` belonging to `y` must also contain `x`. It should automatically stay in sync from both sides of the relationship. The matching algorithm will do that (slowly), but we also care about some of the metadata behind a match, like how long users have been considered a match.

To solve this problem and meet all of the requirements, we can create a bi-directional, self-referential, self-syncing, many-to-many association between users using a `has_many :through` association with a join model to keep track of a user's matches.

Lets start by creating our join model, `Match`, to belong to users via the `user_id` and `matched_user_id` columns:

```ruby
# db/migrations/create_matches.rb
class CreateMatches < ActiveRecord::Migration
  def change
    create_table :matches do |t|
      t.references :user, index: true, foreign_key: true
      t.references :matched_user, index: true

      t.timestamps
    end

    add_index :matches, [:user_id, :matched_user_id], unique: true
    add_foreign_key :matches, :users, column: :matched_user_id
  end
end

# app/models/match.rb
class Match < ActiveRecord::Base
  belongs_to :user
  belongs_to :matched_user, class_name: "User"
end
```

And then add our `has_many` and `has_many :through` associations to our `User` model:

```ruby
# app/models/user.rb
class User < ActiveRecord::Base
  has_many :matches
  has_many :matched_users, through: :matches
end
```

This is pretty straightforward. Now if we have a user Alice and add Bob to her matched users collection, we will see that it contains Bob:

```ruby
alice = User.find_by(email: 'alice@example.com')
bob = User.find_by(email: 'bob@example.com')
alice.matched_users << bob
alice.matched_users # => [bob]
```

However, if we look from Bob's point of view, we can't see that he is matched to Alice:

```ruby
bob.matched_users # => []
```

But we want to make sure that any time Alice is matched with  Bob, Bob also is matched with Alice using the same `matched_users` API. In order to do this, we'll add an `after_create` and an `after_destroy` callback to the `Match` model. Any time a match is added or removed, we'll create or destroy an inverse record, respectively:

```ruby
# app/models/match.rb
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

An inverse match is simply a match record where the `user_id` and `matched_user_id` are flipped, so that when we look up `matches` for Bob, we will be able to find matches with his `id` as the `matched_users` foreign key. In order to be thorough and conservative with our database records, we make sure we only create an inverse if one doesn't already exist, and we'll destroy all inverses that may have been created. Now, if we try adding Bob to Alice again, we'll see that they both have each other as matches:

```ruby
alice.matched_users << bob
alice.matched_users # => [bob]
bob.matched_users # => [alice]
```

Awesome, this is exactly what we want. *But wait*. Let's make sure that these stay in sync if we remove Bob from Alice's matched users:

```ruby
alice.matched_users # => [bob]
alice.matched_users.destroy_all # => [bob]
alice.matched_users # => []
bob.matched_users # => [alice]
```

Even though we have an `after_destroy` callback set up, Alice is still in Bob's matched users. [Here's why](http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#module-ActiveRecord::Associations::ClassMethods-label-Delete+or+destroy-3F):

> For has_many, destroy and destroy_all will always call the destroy method of the record(s) being removed so that callbacks are run. However delete and delete_all will either do the deletion according to the strategy specified by the :dependent option, or if no :dependent option is given, then it will follow the default strategy. The default strategy is to do nothing (leave the foreign keys with the parent ids set), *except for has_many :through, where the default strategy is delete_all (delete the join records, without running their callbacks)*.

So in order to make sure we maintain the bi-directional integrity of the association, we need to change the dependent strategy on the `User#has_many` association so that it actually calls `destroy` when we modify via association methods:

```ruby
# app/models/user.rb
class User < ActiveRecord::Base
  has_many :matches
  has_many :matched_users, through: :matches,
                           dependent: :destroy
end
```

Keep in mind here that on a `has_many :through` association, when `destroy` or `delete` methods are called, it will always remove the *link* between the two models, not the models themselves. By adding `dependent: :destroy`, we are telling ActiveRecord that we want to make sure callbacks are run whenever we remove an item from the collection. Now if we try again, we should see what we expect:

```ruby
alice.matched_users # => [bob]
alice.matched_users.destroy_all # => [bob]
alice.matched_users # => []
bob.matched_users # => []
```

With this setup, I can judiciously run my matching algorithm for a user only when it makes sense to do it (e.g. after they update their profile), and all users' matches will be automatically kept in sync without having to re-run the match algorithm for everyone. All user matches and unmatches will automatically be reciprocated when I make the change on a single user record. So now, instead of a controller that looks like this:

```ruby
# app/controllers/matches_controller.rb
def index
  # takes over 1 second
  @matched_users = MatchMaker.matches_for(current_user)
                             .page(params[:page])
end
```

We can do something more like this:

```ruby
# app/controllers/matches_controller.rb
before_action :resync_matches, only: :index

def index
  # several orders of magnitude faster
  @matched_users = current_user.matched_users
                               .page(params[:page])
end

private

def resync_matches
  # only resync if we have to
  if current_user.matches_outdated?
    new_matches = MatchMaker.matches_for(current_user)
    current_user.matched_users.replace(new_matches)
  end
end
```

This blog was written in parallel with [an example Rails project](https://github.com/shekibobo/user-to-user-example) using TDD, so you can clone and experiment with the code yourself.

Happy match-making!
