class Group < ActiveRecord::Base

  PERMISSION_CATEGORIES = [:everyone, :members, :admins, :parent_group_members]

  attr_accessible :name, :viewable_by, :parent_id, :parent, :cannot_contribute
  attr_accessible :members_invitable_by, :email_new_motion, :description

  validates_presence_of :name
  validates_inclusion_of :viewable_by, in: PERMISSION_CATEGORIES
  validates_inclusion_of :members_invitable_by, in: PERMISSION_CATEGORIES
  validate :limit_inheritance
  validates :description, :length => { :maximum => 250 }
  validates :name, :length => { :maximum => 250 }
  validates :max_size, presence: true, if: :is_a_parent?
  validate :max_size_is_nil, if: :is_a_subgroup?

  serialize :sectors_metric, Array

  after_initialize :set_defaults
  before_validation :set_max_group_size, on: :create
  after_create :add_creator_as_admin

  default_scope where(:archived_at => nil)

  has_many :memberships,
    :conditions => {:access_level => Membership::MEMBER_ACCESS_LEVELS},
    :dependent => :destroy,
    :extend => GroupMemberships,
    :include => :user,
    :order => "LOWER(users.name)"
  has_many :membership_requests,
    :conditions => {:access_level => 'request'},
    :class_name => 'Membership',
    :dependent => :destroy
  has_many :admin_memberships,
    :conditions => {:access_level => 'admin'},
    :class_name => 'Membership',
    :dependent => :destroy
  has_many :users, :through => :memberships, # TODO: rename to members
           :conditions => { :invitation_token => nil }
  has_many :invited_users, :through => :memberships, source: :user,
           :conditions => "invitation_token is not NULL"
  has_many :users_and_invited_users, through: :memberships, source: :user
  has_many :requested_users, :through => :membership_requests, source: :user
  has_many :admins, through: :admin_memberships, source: :user
  has_many :discussions, :dependent => :destroy
  has_many :motions, :through => :discussions
  has_many :motions_in_voting_phase,
           :through => :discussions,
           :source => :motions,
           :conditions => { phase: 'voting' },
           :order => 'close_date'
  has_many :motions_closed,
           :through => :discussions,
           :source => :motions,
           :conditions => { phase: 'closed' },
           :order => 'close_date DESC'

  belongs_to :parent, :class_name => "Group"
  has_many :subgroups, :class_name => "Group", :foreign_key => 'parent_id'

  belongs_to :creator,  :class_name => "User"

  delegate :include?, :to => :users, :prefix => true
  delegate :users, :to => :parent, :prefix => true
  delegate :name, :to => :parent, :prefix => true
  delegate :email, :to => :creator, :prefix => true

  #
  # ACCESSOR METHODS
  #


  def beta_features
    if parent && (parent.beta_features == true)
      true
    else
      self[:beta_features]
    end
  end

  def beta_features?
    beta_features
  end

  def viewable_by
    value = read_attribute(:viewable_by)
    value.to_sym if value.present?
  end

  def viewable_by=(value)
    write_attribute(:viewable_by, value.to_s)
  end

  def members_invitable_by
    value = read_attribute(:members_invitable_by)
    value.to_sym if value.present?
  end

  def members_invitable_by=(value)
    write_attribute(:members_invitable_by, value.to_s)
  end

  def full_name(separator= " - ")
    if parent
      parent_name + separator + name
    else
      name
    end
  end

  def root_name
    if parent
      parent_name
    else
      name
    end
  end

  def admin_email
    if admins.exists?
      admins.first.email
    elsif creator
      creator.email
    else
      "noreply@loomio.org"
    end
  end

  def parent_members_visible_to(user)
    if user.can?(:add_members, parent)
      parent.users_and_invited_users.sorted_by_name
    else
      parent.users.sorted_by_name
    end
  end

  #
  # ACTIVITY METHODS
  #
  #

  def activity_since_last_viewed?(user)
    membership = membership(user)
    if membership
      new_comments_since_last_looked_at_group = discussions
        .includes(:comments)
        .where('comments.user_id <> ? AND comments.created_at > ?' , user.id, membership.group_last_viewed_at)
        .count > 0
      new_comments_since_last_looked_at_discussions = discussions
        .joins('INNER JOIN discussion_read_logs ON discussions.id = discussion_read_logs.discussion_id')
        .where('discussion_read_logs.user_id = ? AND discussions.last_comment_at > discussion_read_logs.discussion_last_viewed_at',  user.id)
        .count > 0
      unread_comments = new_comments_since_last_looked_at_group &&
                        new_comments_since_last_looked_at_discussions

      # TODO: Refactor this to an active record query and write tests for it
      unread_new_discussions = Discussion.find_by_sql(["
        (SELECT discussions.id FROM discussions WHERE group_id = ? AND discussions.created_at > ?)
        EXCEPT
        (SELECT discussions.id FROM discussions
         INNER JOIN discussion_read_logs ON discussions.id = discussion_read_logs.discussion_id
         WHERE discussions.group_id = ? AND discussion_read_logs.user_id = ?);",
        id, membership.group_last_viewed_at, id, user.id])

      return true if unread_comments || unread_new_discussions.present?
    end
    false
  end

  #
  # MEMBERSHIP METHODS
  #

  def membership(user)
    memberships.where("group_id = ? AND user_id = ?", id, user.id).first
  end

  def add_request!(user)
    if user_can_join?(user) && !user_membership_or_request_exists?(user)
      membership = user.memberships.create!(:group_id => id)
      GroupMailer.new_membership_request(membership).deliver
      membership
    end
  end

  def add_member!(user, inviter=nil)
    membership = find_or_build_membership_for_user(user)
    membership.promote_to_member!(inviter)
    membership
  end

  def add_admin!(user)
    membership = find_or_build_membership_for_user(user)
    membership.make_admin!
    membership
  end

  def find_or_build_membership_for_user(user)
    membership = Membership.where(:user_id => user, :group_id => self).first
    membership ||= user.memberships.build(:group_id => id)
  end

  def has_admin_user?(user)
    return true if admins.include?(user)
    return true if (parent && parent.admins.include?(user))
  end

  def user_membership_or_request_exists? user
    Membership.where(:user_id => user, :group_id => self).exists?
  end

  def user_can_join? user
    is_a_parent? || user_is_a_parent_member?(user)
  end

  def is_a_parent?
    parent_id.nil?
  end

  def is_a_subgroup?
    parent_id.present?
  end

  def user_is_a_parent_member? user
    user.group_membership(parent)
  end

  #
  # OTHER METHODS
  #

  def create_welcome_loomio
    unless parent
      comment_str = "Hey folks, I've been thinking it's time for a holiday. I know some people might be worried about our carbon footprint, but I have a serious craving for space-cheese!

What does everyone think?"
      description_str = "Welcome to Loomio, a new tool for group decision-making.

By engaging on a topic, discussing various perspectives and information, and addressing any concerns that arise, your group can put their heads together to find the best way forward.

You can use this example discussion to play around with the features of the tool.

To get the ball rolling, Loomio Helper Bot thinks it would be a great idea for your group to take a holiday together. The pie graph on the right shows how your group feels about the proposal. You can have your say by clicking on one of the decision buttons underneath. "
      motion_str = "Loomio Helper Bot is really keen for your group to invest in a trip to the moon. Apparently the space-cheese is delicious. But the implications for your carbon footprint are worrying.

Is it a good idea? Loomio Helper Bot wants to know what you think!

If you're clear about your position, click one of the icons below (hover over the decision buttons for a description of what each one means).

You'll be prompted to make a short statement about the reason for your decision. This makes it easy to see a summary of what everyone thinks and why. You can change your mind and edit your decision freely until the proposal closes."
      user = User.loomio_helper_bot
      membership = add_member!(user)
      discussion = user.authored_discussions.create!(:group_id => id,
        :title => "Example Discussion: Welcome and introduction to Loomio!",
        :description => description_str)
      discussion.add_comment(user, comment_str)
      motion = user.authored_motions.new(:discussion_id => discussion.id, :name => "We should have a holiday on the moon!",
        :description => motion_str, :close_date => Time.now + 7.days)
      motion.save
      membership.destroy
    end
  end


  #
  # PRIVATE METHODS
  #

  private

  def set_max_group_size
    self.max_size = 50 if (is_a_parent? && max_size.nil?)
  end

  def set_defaults
    self.viewable_by ||= :members if parent_id.nil?
    self.viewable_by ||= :parent_group_members unless parent_id.nil?
    self.members_invitable_by ||= :members
  end

  def add_creator_as_admin
    add_admin! creator unless creator == User.loomio_helper_bot
  end

  # Validators
  def limit_inheritance
    unless parent_id.nil?
      errors[:base] << "Can't set a subgroup as parent" unless parent.parent_id.nil?
    end
  end

  def max_size_is_nil
    unless max_size.nil?
      errors.add(:max_size, "Cannot be nil")
    end
  end
end
