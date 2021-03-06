require 'diggit/analysis/complexity/report'

def complexity_test_repo
  TemporaryAnalysisRepo.create do |repo|
    # Two weeks ago
    repo.write('master.rb', 'one')
    repo.commit('initial', time: Time.zone.now.advance(days: -13))

    repo.write('master.rb', 'two')
    repo.commit('same day', time: Time.zone.now.advance(days: -13))

    # One week ago
    repo.write('master.rb', 'three')
    repo.write('to_be_removed.rb', 'three')
    repo.commit('one week ago', time: Time.zone.now.advance(days: -6))

    # Branch yesterday
    repo.branch('feature')
    repo.write('master.rb', 'four')
    # This verifies fix for https://rollbar.com/lawrencejones/diggit/items/55/
    repo.rm('to_be_removed.rb')
    repo.commit('yesterday', time: Time.zone.now.advance(days: -1))
  end
end

RSpec.describe(Diggit::Analysis::Complexity::Report) do
  subject(:report) { described_class.new(repo, { base: base, head: head }, config) }

  let(:head) { repo.branches.find { |b| b.name == 'feature' }.target.oid }
  let(:base) { repo.branches.find { |b| b.name == 'master' }.target.oid }

  let(:repo) { complexity_test_repo }

  let(:config) do
    { change_window: change_window, change_threshold: change_threshold, ignore: ignore }
  end
  let(:change_threshold) { 50.0 }
  let(:change_window) { 3 }
  let(:ignore) { [] }

  # Stub the complexity scores, to allow testing detection logic without contrived
  # code examples
  before do
    allow(Diggit::Analysis::Complexity::WhitespaceAnalysis).
      to receive(:new) do |contents|
        double(std: complexity_scores.fetch(contents))
      end
  end

  it 'defines a name' do
    expect(described_class::NAME).to eql('Complexity')
  end

  describe '.comments' do
    subject(:comments) { report.comments }
    let(:master_comment) { comments.find { |c| c[:meta][:file][/master.rb/] } }

    context 'when complexity increased <50% over last three changes' do
      # one & two are grouped in same day, so changes should see .6, .7, .8
      # .8 / .6 = 1.33 < 1.5
      let(:complexity_scores) do
        { 'one' => 0.5,
          'two' => 0.6,
          'three' => 0.7,
          'four' => 0.8 }
      end

      it { is_expected.to be_empty }
    end

    context 'when complexity increased >50% over last three changes' do
      # apparent changes .6, penultimate_complexity, .95
      # .95 / .6 = 1.58 > 1.5
      let(:complexity_scores) do
        { 'one' => 0.5,
          'two' => 0.6,
          'three' => penultimate_complexity,
          'four' => 0.95 }
      end

      context 'and latest commit is increase' do
        let(:penultimate_complexity) { 0.7 }

        it 'comments' do
          expect(master_comment).to include(
            report: 'Complexity',
            message: /increased in complexity by 58% over the last 12 days/,
            location: 'master.rb:1',
            index: 'master.rb',
            meta: {
              file: 'master.rb',
              complexity_increase: 58.33,
              head: /^\S{40}$/, base: /^\S{40}$/
            }
          )
        end

        context 'when user defined threshold is greater than change' do
          let(:change_threshold) { 75.0 }
          it { is_expected.to be_empty }
        end

        context 'when user defined window is smalled than current' do
          let(:change_window) { 2 }
          it { is_expected.to be_empty }
        end

        context 'and file is in ignore list' do
          let(:ignore) { ['master.rb'] }
          it { is_expected.to be_empty }
        end
      end

      context 'and latest commit is decrease' do
        let(:penultimate_complexity) { 1.0 }

        it { is_expected.to be_empty }
      end
    end
  end
end
