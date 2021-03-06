require_relative 'temporary_analysis_repo'
require 'diggit/analysis/pipeline'

def pipeline_test_repo(&block)
  TemporaryAnalysisRepo.create do |repo|
    repo.write('file.c', <<-C)
    int main(int argc, char **argv) {
      return 0;
    }
    C
    repo.commit('initial commit')

    repo.write('.gitignore', %(*.o))
    repo.write('file.c', <<-C)
    int main(int argc, char **argv) {
      printf("Second commit change");
      return 0;
    }
    C
    repo.commit('second commit')

    repo.write('README.md', <<-MD)
    # Simple C Project
    Keep it real dawg (⌐■_■)
    MD
    repo.write('file.c', <<-C)
    int main(int argc, char **argv) {
      printf("Second commit change");
      printf("Third commit change");
      return 0;
    C
    repo.commit('third commit')

    yield(repo) unless block.nil?
  end
end

RSpec.describe(Diggit::Analysis::Pipeline) do
  subject(:pipeline) do
    described_class.new(repo, head: head, base: base, gh_path: gh_path)
  end
  let(:repo) { pipeline_test_repo }
  let(:gh_path) { 'owner/repo' }

  let(:head) { repo.head.target.oid }
  let(:base) do
    Rugged::Walker.new(repo).tap do |w|
      w.sorting(Rugged::SORT_DATE | Rugged::SORT_REVERSE)
      w.push(repo.head.target)
    end.first.oid
  end

  def mock_reporter(name, mock_comments, &block)
    Class.new do
      const_set(:NAME, name)
      define_method(:initialize) { |repo, args, conf| yield repo if block }
      define_method(:comments) { mock_comments }
    end
  end

  let(:mutating_reporter) do
    mock_reporter('Mutating', ['ran mutating_reporter']) do |repo|
      File.write(File.join(repo.workdir, 'new_file'), 'contents')
      repo.index.add(path: 'new_file', mode: 0100644,
                     oid: Rugged::Blob.from_workdir(repo, 'new_file'))
      commit_tree = repo.index.write_tree
      repo.index.write
      # rubocop:disable Rails/Date
      person = { email: 'e', name: 'n', time: Time.zone.now.to_time }
      # rubocop:enable Rails/Date
      Rugged::Commit.create(repo, message: 'a new commit', tree: commit_tree,
                                  author: person, committer: person,
                                  parents: [repo.head.target].compact, update_ref: 'HEAD')
    end
  end

  before { stub_const('Diggit::Analysis::Pipeline::REPORTERS', reporters) }
  let(:reporters) { [mock_reporter('A', %w(1a 1b)), mock_reporter('B', %w(2a 2b))] }

  context 'when the given HEAD sha is not in repo' do
    let(:head) { 'a' * 40 }
    it 'raises Pipeline::BadGitHistory' do
      expect { pipeline }.to raise_exception(described_class::BadGitHistory)
    end
  end

  describe '#aggregate_comments' do
    subject(:comments) { pipeline.aggregate_comments }

    it 'collects comments from all reporters' do
      expect(comments).to match_array(%w(1a 1b 2a 2b))
    end

    it 'logs running each reporter' do
      allow(pipeline).to receive(:info) do |&block|
        expect(block.call).to match(/\S+\.\.\./)
      end
      comments
    end

    context 'when project defines reporter config' do
      let(:repo) do
        pipeline_test_repo do |repo|
          repo.write('.diggit.yml', <<-YAML)
          MockReporter:
            user_config_key: value
          YAML
          repo.commit('Adds .diggit.yml')
        end
      end
      let(:reporters) { [reporter] }
      let(:reporter) { mock_reporter('MockReporter', ['ran mock reporter']) }

      it 'initializes reporter with reporter config' do
        expect(reporter).
          to receive(:new).
          with(repo, anything, user_config_key: 'value').
          and_call_original
        comments
      end
    end

    context 'when diff changes too many files' do
      before { stub_const("#{described_class}::MAX_FILES_CHANGED", 1) }

      it { is_expected.to be_empty }

      it 'logs that it is skipping analysis' do
        expect(pipeline).to receive(:info) do |&message_block|
          expect(message_block.call).to match(/3 files changed, too large, skipping/)
        end
        comments
      end
    end

    context 'with bad mutating reporters' do
      let(:reporters) { [mutating_reporter, verifying_reporter] }
      let(:verifying_reporter) do
        mock_reporter('Verifying', ['ran_verifying_reporter']) do |repo|
          expect(repo.head.target.oid).to eql(head)
          expect(File.exist?(File.join(repo.workdir, 'new_file'))).to be(false)
        end
      end

      it 'does not persist index or checkout' do
        expect(comments).to eql(['ran mutating_reporter', 'ran_verifying_reporter'])
      end
    end
  end
end
