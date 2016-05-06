require 'que'

require_relative '../logger'
require_relative '../models/project'
require_relative '../models/pull_analysis'
require_relative '../github/comment_generator'
require_relative '../github/client'

module Diggit
  module Jobs
    class PushAnalysisComments < Que::Job
      include InstanceLogger

      def run(pull_analysis_id)
        @pull_analysis = PullAnalysis.find(pull_analysis_id)
        @comment_generator = Github::CommentGenerator.
          new(project.gh_path, pull_analysis.pull, Github.client)

        if pull_analysis.pushed_to_github
          info { "Already commented for analysis #{pull_analysis.id}, doing nothing" }
          return destroy
        end

        ActiveRecord::Base.transaction do
          push_comments_to_github
          pull_analysis.update!(pushed_to_github: true)
          destroy
        end
      end

      private

      attr_reader :pull_analysis, :comment_generator
      delegate :project, to: :pull_analysis

      def push_comments_to_github
        pending_comments.each do |comment|
          comment_generator.add_comment(comment['message'], comment['location'])
        end
        info { "Pushing #{pending_comments.count} comments to github..." }
        comment_generator.push
      end

      def pending_comments
        @pending_comments ||= pull_analysis.comments.reject do |comment|
          existing_comments.include?(comment.slice('report', 'index'))
        end
      end

      def existing_comments
        @existing_comments ||= existing_analyses.
          flat_map(&:comments).
          map { |comment| comment.slice('report', 'index') }
      end

      def existing_analyses
        PullAnalysis.
          where(project: project, pull: pull_analysis.pull).
          where.not(id: pull_analysis.id)
      end
    end
  end
end