# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'tina4/metrics'

RSpec.describe Tina4::Metrics do
  around do |example|
    Dir.mktmpdir('tina4-metrics-handoff') do |directory|
      @directory = directory
      File.write(File.join(directory, 'orders.rb'), "def total(lines)\n  lines.length\nend\n")
      example.run
    end
  end

  it 'hands full analysis to the native CLI' do
    expect(described_class.engine_path).not_to be_nil
    result = described_class.full_analysis(@directory)
    expect(result['engine']).to eq('tina4-cli')
    expect(result['files_analyzed']).to be >= 1
    expect(result).to include('file_metrics', 'dependency_graph')
    expect(result['file_metrics'].first).to include('has_referencing_test')
    expect(result['file_metrics'].first).not_to include('has_tests')
  end

  it 'hands file detail to the native CLI' do
    result = described_class.file_detail(File.join(@directory, 'orders.rb'))
    expect(result['engine']).to eq('tina4-cli')
    expect(result['path']).to end_with('orders.rb')
    expect(result['function_count']).to be >= 1
    expect(result['functions']).to be_an(Array)
    expect(result['functions'].first['name']).to eq('total')
  end

  it 'fails loudly for a missing file' do
    expect { described_class.file_detail(File.join(@directory, 'missing.rb')) }
      .to raise_error(Tina4::MetricsEngineError, /no such file/)
  end
end
