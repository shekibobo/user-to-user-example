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

  def match_created_at
    Time.zone.parse(self[:match_created_at]) if self[:match_created_at]
  end
end
