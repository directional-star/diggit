require 'que'
require 'diggit/routes/github_webhooks'

RSpec.describe(Diggit::Routes::GithubWebhooks::Create) do
  subject(:instance) { described_class.new(context, null_middleware, {}) }

  let(:context) { { request: request } }
  let(:request) { mock_request_for(url, params: webhook, method: 'POST') }

  let(:pr_opened) { load_json_fixture('api/github_webhooks/pr_opened.fixture.json') }
  let(:hook_registered) do
    load_json_fixture('api/github_webhooks/hook_registered.fixture.json')
  end

  let(:webhook) { pr_opened }
  let(:webhook_gh_path) { webhook.fetch('repository').fetch('full_name') }
  let(:url) { 'https://diggit.com/api/github_webhooks' }

  let(:head) { webhook['pull_request']['head']['sha'] }
  let(:base) { webhook['pull_request']['base']['sha'] }

  before { Que.mode = :off }

  shared_examples 'ignores webhook' do |status, body|
    it 'does not queue AnalysePull job' do
      expect(Diggit::Jobs::AnalysePull).
        not_to receive(:enqueue)
      instance.call
    end

    it { is_expected.to respond_with_status(status) }
    it { is_expected.to respond_with_json(body.stringify_keys) }
  end

  shared_examples 'takes action on webhook' do
    it { is_expected.to respond_with_status(200) }
    it { is_expected.to respond_with_json('message' => 'project_analysis_queued') }

    it 'enqueues AnalysePull job' do
      expect(Diggit::Jobs::AnalysePull).
        to receive(:enqueue).
        with(project.gh_path, webhook['number'], head, base)
      instance.call
    end
  end

  context 'when project does not exist' do
    include_examples 'ignores webhook', 404, message: 'project_not_found'
  end

  context 'when project exists' do
    context 'that is not watched' do
      let!(:project) { FactoryGirl.create(:project, gh_path: webhook_gh_path) }
      include_examples 'ignores webhook', 200, message: 'project_not_watched'
    end

    context 'that is watched' do
      let!(:project) { FactoryGirl.create(:project, :watched, gh_path: webhook_gh_path) }

      context 'with hook registered webhook' do
        let(:webhook) { hook_registered }
        include_examples 'ignores webhook', 200, message: 'project_not_watched_action'
      end

      context 'with non-opened/synchronize webhook' do
        before { webhook['action'] = 'closed' }
        include_examples 'ignores webhook', 200, message: 'project_not_watched_action'
      end

      context 'with opened webhook' do
        before { webhook['action'] = 'opened' }
        include_examples 'takes action on webhook'
      end

      context 'with synchronize webhook' do
        before { webhook['action'] = 'synchronize' }
        include_examples 'takes action on webhook'
      end
    end
  end
end
