# rubocop:disable Metrics/AbcSize
namespace :frequent_pattern do
  BENCHMARK_TASK_ARGS = [:support_range, :max_items, :no_of_changesets].freeze

  def load_rails_changesets(limit = 10_000)
    require 'rugged'
    require 'diggit/services/cache'

    Diggit::Services::Cache.get('frequent_pattern/rails/changesets').
      map { |entry| entry[:changeset] }.
      first(limit)
  end

  desc 'Walk rails repository to fill changeset cache'
  task :walk_rails, [:rails_path] do |_, args|
    require 'diggit/analysis/change_patterns/changeset_generator'

    puts('Loading rails repo...')
    rails_path = File.join(Rake.application.original_dir, args.fetch(:rails_path))
    rails = Rugged::Repository.new(rails_path)

    puts('Walking commit history...')
    changesets = Diggit::Analysis::ChangePatterns::ChangesetGenerator.
      new(rails, gh_path: 'frequent_pattern/rails').changesets

    puts("Loaded #{changesets.size} changesets into cache!")
  end

  desc 'Benchmarks file suggestion'
  task :benchmark_file_suggestion do
    require 'benchmark'
    require 'hamster'
    require 'diggit/services/cache'
    require 'diggit/analysis/change_patterns/file_suggester'

    itemsets = Diggit::Services::Cache.get('frequent_pattern/rails/itemsets').
      map { |is| { items: Hamster::SortedSet.new(is['items']), support: is['support'] } }
    puts("Loaded #{itemsets.size} changesets!")

    suggester = Diggit::Analysis::ChangePatterns::FileSuggester.new(itemsets)
    files = ['activerecord/lib/active_record/connection_adapters/abstract_adapter.rb',
             'activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb']

    puts('Starting...')
    suggestions = nil
    run_time = Benchmark.measure do
      suggestions = suggester.suggest(files)
    end
    puts("Found #{suggestions.count} suggestions!")
    puts("#{run_time}\n")
  end

  desc 'Loads rails frequent itemsets into cache'
  task :generate_rails_itemsets do
    require 'diggit/services/cache'
    require 'diggit/analysis/change_patterns/fp_growth'

    changesets = load_rails_changesets(10_000)
    puts("Loaded #{changesets.size} changesets!")

    patterns = Diggit::Analysis::ChangePatterns::FpGrowth.
      new(changesets,
          min_support: 5,
          max_items: 25).frequent_itemsets
    puts("Found #{patterns.size} frequent itemsets!")

    Diggit::Services::Cache.store('frequent_pattern/rails/itemsets', patterns.as_json)
    puts('Done!')
  end

  # Runs and profiles blocks that generate frequent pattern sets from the rails
  # changesets.
  def benchmark_fp_discovery(algorithm, args, _dump_dir)
    require 'yaml'
    require 'ruby-prof'
    require 'fileutils'

    require 'diggit/services/cache'

    support_range = Range.new(*args.fetch(:support_range).split('..').map(&:to_i))
    max_items = args.fetch(:max_items, 20).to_i
    no_of_changesets = args.fetch(:no_of_changesets, 10_000).to_i
    patterns = nil

    changesets = load_rails_changesets(no_of_changesets)
    puts("Loaded #{changesets.size} changesets!")

    support_range.to_a.reverse.each do |min_support|
      puts("Starting: #{{ min_support: min_support, max_items: max_items }}...")
      run_time = Benchmark.measure do
        patterns = algorithm.new(changesets,
                                 min_support: min_support,
                                 max_items: max_items).frequent_itemsets
      end
      puts("Found #{patterns.size} frequent patterns!")
      puts("#{run_time}\n")
    end
  end

  namespace :fp_growth do
    FP_GROWTH_DUMP_DIR = File.join(Rake.application.original_dir, 'tmp/fp_growth.dump')

    desc 'Benchmark Diggit::Analysis::ChangePatterns::FpGrowth'
    task :benchmark, BENCHMARK_TASK_ARGS do |_, args|
      require 'diggit/analysis/change_patterns/fp_growth'
      benchmark_fp_discovery(Diggit::Analysis::ChangePatterns::FpGrowth,
                             args, FP_GROWTH_DUMP_DIR)
    end
  end

  namespace :apriori do
    APRIORI_DUMP_DIR = File.join(Rake.application.original_dir, 'tmp/apriori.dump')

    desc 'Benchmark Diggit::Analysis::ChangePatterns::Apriori'
    task :benchmark, BENCHMARK_TASK_ARGS do |_, args|
      require 'diggit/analysis/change_patterns/apriori'
      benchmark_fp_discovery(Diggit::Analysis::ChangePatterns::Apriori,
                             args, APRIORI_DUMP_DIR)
    end
  end
end
