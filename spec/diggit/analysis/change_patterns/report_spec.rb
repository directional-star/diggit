require 'diggit/analysis/change_patterns/report'

# rubocop:disable Metrics/MethodLength
def change_patterns_test_repo
  TemporaryAnalysisRepo.create do |repo|
    repo.write('Gemfile', "gem 'sinatra'")
    repo.write('app.rb', 'Sinatra::App')
    repo.commit('initial')

    repo.write('app.rb', "require 'app_controller'; Sinatra::App")
    repo.write('app_controller.rb', 'class AppController; end')
    repo.commit('app controller')

    repo.write('app_template.html', '<html></html>')
    repo.write('app_controller.rb', <<-RUBY)
    class AppController
      def render_template
        render('app_template.html')
      end
    end
    RUBY
    repo.commit('render app_template')

    repo.write('app_template.html', '<html> @first </html>')
    repo.write('app_controller.rb', <<-RUBY)
    class AppController
      def render_template
        render('app_template.html', first: 'first')
      end
    end
    RUBY
    repo.commit('@first param for app_template render')

    repo.write('app_template.html', '<html> @first @second</html>')
    repo.write('app_controller.rb', <<-RUBY)
    class AppController
      def render_template
        render('app_template.html', first: 'first', second: 'second')
      end
    end
    RUBY
    repo.commit('@second param for app_template render')

    repo.write('app_template.html', <<-HTML)
    <html>
      <ul>
        <li>@first</li>
        <li>@second</li>
      </ul>
    </html>
    HTML
    repo.commit('Add additional formatting to app_template')

    # Create suspect feature branch
    repo.branch('feature')
    repo.write('app_template.html', '<html> @first @second @third </html>')
    repo.commit('@third param for app_template')
  end
end
# rubocop:enable Metrics/MethodLength

RSpec.describe(Diggit::Analysis::ChangePatterns::Report) do
  subject(:report) { described_class.new(repo, head: head, base: base, gh_path: gh_path) }

  let(:head) { repo.branches.find { |b| b.name == 'feature' }.target.oid }
  let(:base) { repo.branches.find { |b| b.name == 'master' }.target.oid }

  let(:repo) { change_patterns_test_repo }
  let(:gh_path) { 'owner/repo' }

  before do
    allow(described_class).to receive(:min_support_for).and_return(min_support)
    stub_const("#{described_class}::MIN_CONFIDENCE", min_confidence)
    stub_const("#{described_class}::MAX_CHANGESET_SIZE", max_changeset_size)
  end

  let(:min_support) { 1 }
  let(:min_confidence) { 0.5 }
  let(:max_changeset_size) { 10 }

  describe '.min_support_for' do
    before { allow(described_class).to receive(:min_support_for).and_call_original }

    it 'yields 5 for changesets sizes < 5,000' do
      expect(described_class.min_support_for(3_000)).to equal(5)
    end

    it 'linearly interpolates by the thousand up to 10,000' do
      expect(described_class.min_support_for(7_500)).to equal(7)
    end

    it 'caps out at 10 for anything over 10,000' do
      expect(described_class.min_support_for(12_000)).to equal(10)
    end
  end

  describe '.comments' do
    subject(:comments) { report.comments }
    let(:controller_comment) { comments.find { |c| c[:index] == 'app_controller.rb' } }

    context 'when there is insufficient support' do
      let(:min_support) { 5 }

      it { is_expected.to be_empty }
    end

    context 'when there is insufficient confidence' do
      let(:min_confidence) { 0.8 }

      it { is_expected.to be_empty }
    end

    context 'when changeset sizes were too large' do
      let(:max_changeset_size) { 1 }

      it { is_expected.to be_empty }
    end

    context 'when sufficient support and confidence' do
      it 'comments' do
        expect(controller_comment).to include(
          report: 'ChangePatterns',
          index: 'app_controller.rb',
          location: 'app_controller.rb:1',
          message: /was modified in 75% of past changes involving/,
          meta: {
            missing_file: 'app_controller.rb',
            confidence: 0.75,
            antecedent: ['app_template.html'],
          }
        )
      end
    end
  end
end
