module Shipit
  class Commit < ActiveRecord::Base
    include DeferredTouch

    AmbiguousRevision = Class.new(StandardError)

    belongs_to :stack
    has_many :deploys
    has_many :statuses, -> { order(created_at: :desc) }, dependent: :destroy
    has_many :commit_deployments, dependent: :destroy

    deferred_touch stack: :updated_at

    after_commit { broadcast_update }
    after_create { stack.update_undeployed_commits_count }

    after_commit :schedule_refresh_statuses!, :schedule_fetch_stats!, :schedule_continuous_delivery, on: :create

    belongs_to :author, class_name: 'User', inverse_of: :authored_commits
    belongs_to :committer, class_name: 'User', inverse_of: :commits

    scope :reachable, -> { where(detached: false) }

    delegate :broadcast_update, :github_repo_name, :hidden_statuses, :required_statuses,
             :soft_failing_statuses, to: :stack

    def self.newer_than(commit)
      return all unless commit
      where('id > ?', commit.try(:id) || commit)
    end

    def self.until(commit)
      return all unless commit
      where('id <= ?', commit.try(:id) || commit)
    end

    def self.successful
      preload(:statuses).to_a.select(&:success?)
    end

    def self.detach!
      Commit.where(id: ids).update_all(detached: true)
    end

    def self.by_sha(sha)
      if sha.to_s.size < 6
        raise AmbiguousRevision, "Short SHA1 #{sha} is ambiguous (too short)"
      end

      commits = where('sha like ?', "#{sha}%").take(2)
      raise AmbiguousRevision, "Short SHA1 #{sha} is ambiguous (matches multiple commits)" if commits.size > 1
      commits.first
    end

    def self.by_sha!(sha)
      by_sha(sha) || raise(ActiveRecord::RecordNotFound, "Couldn't find commit with sha #{sha}")
    end

    def self.from_github(commit)
      new(
        sha: commit.sha,
        message: commit.commit.message,
        author: User.find_or_create_from_github(commit.author || commit.commit.author),
        committer: User.find_or_create_from_github(commit.committer || commit.commit.committer),
        committed_at: commit.commit.committer.date,
        authored_at: commit.commit.author.date,
        additions: commit.stats.try!(:additions),
        deletions: commit.stats.try!(:deletions),
      )
    end

    def reload(*)
      @status = nil
      super
    end

    def self.create_from_github!(commit)
      from_github(commit).save!
    end

    def schedule_refresh_statuses!
      RefreshStatusesJob.perform_later(commit_id: id)
    end

    def refresh_statuses!
      github_statuses = stack.handle_github_redirections { Shipit.github_api.statuses(github_repo_name, sha) }
      github_statuses.each do |status|
        create_status_from_github!(status)
      end
    end

    def create_status_from_github!(github_status)
      add_status do
        statuses.replicate_from_github!(stack_id, github_status)
      end
    end

    def checks
      @checks ||= CommitChecks.new(self)
    end

    delegate :pending?, :success?, :error?, :failure?, :state, to: :status

    def deployable?
      success? || stack.ignore_ci?
    end

    def children
      self.class.where(stack_id: stack_id).newer_than(self)
    end

    def detach_children!
      children.detach!
    end

    def pull_request_url
      parsed && Shipit.github_url("/#{stack.repo_owner}/#{stack.repo_name}/pull/#{pull_request_number}")
    end

    def pull_request_number
      parsed && parsed['pr_id'].to_i
    end

    def pull_request_title
      parsed && parsed['pr_title']
    end

    def pull_request?
      !!parsed
    end

    def short_sha
      sha[0..9]
    end

    def parsed
      @parsed ||= message.match(/\AMerge pull request #(?<pr_id>\d+) from [\w\-.\/]+\n\n(?<pr_title>.*)/)
    end

    def schedule_continuous_delivery
      return unless deployable? && stack.continuous_deployment? && stack.deployable?
      ContinuousDeliveryJob.perform_later(stack)
    end

    def github_commit
      @github_commit ||= Shipit.github_api.commit(github_repo_name, sha)
    end

    def schedule_fetch_stats!
      FetchCommitStatsJob.perform_later(self)
    end

    def fetch_stats!
      update!(
        additions: github_commit.stats.try!(:additions),
        deletions: github_commit.stats.try!(:deletions),
      )
    end

    def status
      @status ||= Status::Group.compact(self, statuses)
    end

    def deployed?
      stack.last_deployed_commit.id >= id
    end

    def deploy_failed?
      stack.deploys.unsuccessful.where(until_commit_id: id).any?
    end

    private

    def add_status
      previous_status = status
      yield
      reload # to get the statuses into the right order (since sorted :desc)
      new_status = status

      payload = {commit: self, stack: stack, status: new_status.state}
      Hook.emit(:commit_status, stack, payload.merge(commit_status: new_status)) if previous_status != new_status
      if previous_status.simple_state != new_status.simple_state && (!new_status.pending? || previous_status.unknown?)
        Hook.emit(:deployable_status, stack, payload.merge(deployable_status: new_status))
      end
      new_status
    end
  end
end
