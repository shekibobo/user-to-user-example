begin
  require 'bundler/inline'
rescue LoadError => e
  $stderr.puts 'Bundler version 1.10 or later is required. Please update your Bundler'
  raise e
end

gemfile(true) do
  source 'https://rubygems.org'
  # Activate the gem you are reporting the issue against.
  gem 'activerecord', '4.2.3'
  gem 'rspec-rails'
  gem 'factory_girl_rails'
  gem 'sqlite3'
end

require 'active_record'
require 'rspec/rails'
require 'logger'

ActiveRecord::Migration.maintain_test_schema!

# This connection will do for database-independent bug reports.
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
  end

  create_table :matches, force: true do |t|
    t.integer :post_id
  end
end

class User < ActiveRecord::Base
end

class Match < ActiveRecord::Base
end

describe User do
  describe "#matched_users" do
    context "when adding users" do
      let(:parent) { create(:user) }
      let(:child) { create(:user) }

      it "adds the parent user to the matched users of the child user" do
        expect(parent.matched_users).to be_empty
        expect(child.matched_users).to be_empty

        parent.matched_users.replace [child]

        expect(parent.reload.matched_users).to eq [child]
        expect(child.reload.matched_users).to eq [parent]
      end
    end

    context "when removing users" do
      let(:parent) { create(:user, matched_users: [child]) }
      let(:child) { create(:user) }

      it "removes parent user from matched users of child user" do
        expect(parent.matched_users).to eq [child]
        expect(child.matched_users).to eq [parent]

        parent.matched_users.replace []

        expect(parent.reload.matched_users).to be_empty
        expect(child.reload.matched_users).to be_empty
      end
    end
  end
end
