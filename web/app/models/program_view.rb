class ProgramView < ApplicationRecord
  belongs_to :user
  validates :program_sid, presence: true, uniqueness: { scope: :user_id }
end
