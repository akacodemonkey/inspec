# encoding: utf-8
# author: Dominik Richter
# author: Christoph Hartmann
# author: John Kerry

require 'rspec/core'
require 'rspec/core/formatters/json_formatter'
require 'rspec_junit_formatter'

# Vanilla RSpec JSON formatter with a slight extension to show example IDs.
# TODO: Remove these lines when RSpec includes the ID natively
class InspecRspecVanilla < RSpec::Core::Formatters::JsonFormatter
  RSpec::Core::Formatters.register self

  private

  # We are cheating and overriding a private method in RSpec's core JsonFormatter.
  # This is to avoid having to repeat this id functionality in both dump_summary
  # and dump_profile (both of which call format_example).
  # See https://github.com/rspec/rspec-core/blob/master/lib/rspec/core/formatters/json_formatter.rb
  #
  # rspec's example id here corresponds to an inspec test's control name -
  # either explicitly specified or auto-generated by rspec itself.
  def format_example(example)
    res = super(example)
    res[:id] = example.metadata[:id]
    res
  end
end

# Minimal JSON formatter for inspec. Only contains limited information about
# examples without any extras.
class InspecRspecMiniJson < RSpec::Core::Formatters::JsonFormatter
  # Don't re-register all the call-backs over and over - we automatically
  # inherit all callbacks registered by the parent class.
  RSpec::Core::Formatters.register self, :dump_summary, :stop

  # Called after stop has been called and the run is complete.
  def dump_summary(summary)
    @output_hash[:version] = Inspec::VERSION
    @output_hash[:statistics] = {
      duration: summary.duration,
    }
  end

  # Called at the end of a complete RSpec run.
  def stop(notification)
    # This might be a bit confusing. The results are not actually organized
    # by control. It is organized by test. So if a control has 3 tests, the
    # output will have 3 control entries, each one with the same control id
    # and different test results. An rspec example maps to an inspec test.
    @output_hash[:controls] = notification.examples.map do |example|
      format_example(example).tap do |hash|
        e = example.exception
        next unless e
        hash[:message] = e.message

        next if e.is_a? RSpec::Expectations::ExpectationNotMetError
        hash[:exception] = e.class.name
        hash[:backtrace] = e.backtrace
      end
    end
  end

  private

  def format_example(example)
    if !example.metadata[:description_args].empty? && example.metadata[:skip]
      # For skipped profiles, rspec returns in full_description the skip_message as well. We don't want
      # to mix the two, so we pick the full_description from the example.metadata[:example_group] hash.
      code_description = example.metadata[:example_group][:description]
    else
      code_description = example.metadata[:full_description]
    end

    res = {
      id: example.metadata[:id],
      status: example.execution_result.status.to_s,
      code_desc: code_description,
    }

    unless (pid = example.metadata[:profile_id]).nil?
      res[:profile_id] = pid
    end

    if res[:status] == 'pending'
      res[:status] = 'skipped'
      res[:skip_message] = example.metadata[:description]
      res[:resource] = example.metadata[:described_class].to_s
    end

    res
  end
end

class InspecRspecJson < InspecRspecMiniJson # rubocop:disable Metrics/ClassLength
  RSpec::Core::Formatters.register self, :stop, :dump_summary
  attr_writer :backend

  def initialize(*args)
    super(*args)
    @profiles = []
    # Will be valid after "start" state is reached.
    @profiles_info = nil
    @backend = nil
  end

  attr_reader :profiles

  # Called by the runner during example collection.
  def add_profile(profile)
    profiles.push(profile)
  end

  def stop(notification)
    super(notification)

    @output_hash[:other_checks] = examples_without_controls
    @output_hash[:profiles] = profiles_info

    examples_with_controls.each do |example|
      control = example2control(example)
      move_example_into_control(example, control)
    end
  end

  def profile_summary
    failed = 0
    skipped = 0
    passed = 0
    critical = 0
    major = 0
    minor = 0

    @all_controls.each do |control|
      next if control[:id].start_with? '(generated from '
      next unless control[:results]
      if control[:results].any? { |r| r[:status] == 'failed' }
        failed += 1
        if control[:impact] >= 0.7
          critical += 1
        elsif control[:impact] >= 0.4
          major += 1
        else
          minor += 1
        end
      elsif control[:results].any? { |r| r[:status] == 'skipped' }
        skipped += 1
      else
        passed += 1
      end
    end

    total = failed + passed + skipped

    { 'total' => total,
      'failed' => {
        'total' => failed,
        'critical' => critical,
        'major' => major,
        'minor' => minor,
      },
      'skipped' => skipped,
      'passed' => passed }
  end

  def tests_summary
    total = 0
    failed = 0
    skipped = 0
    passed = 0

    @all_controls.each do |control|
      next unless control[:results]
      control[:results].each do |result|
        if result[:status] == 'failed'
          failed += 1
        elsif result[:status] == 'skipped'
          skipped += 1
        else
          passed += 1
        end
      end
    end

    { 'total' => total, 'failed' => failed, 'skipped' => skipped, 'passed' => passed }
  end

  private

  def examples
    @examples ||= @output_hash.delete(:controls)
  end

  def examples_without_controls
    examples.find_all { |example| example2control(example).nil? }
  end

  def examples_with_controls
    (examples - examples_without_controls)
  end

  def profiles_info
    @profiles_info ||= profiles.map(&:info!).map(&:dup)
  end

  def example2control(example)
    profile = profile_from_example(example)
    return nil unless profile && profile[:controls]
    profile[:controls].find { |x| x[:id] == example[:id] }
  end

  def profile_from_example(example)
    profiles_info.find { |p| profile_contains_example?(p, example) }
  end

  def profile_contains_example?(profile, example)
    # Heuristic for finding the profile an example came from:
    # Case 1: The profile_id on the example matches the name of the profile
    # Case 2: The profile contains a control that matches the id of the example
    if profile[:name] == example[:profile_id]
      true
    elsif profile[:controls] && profile[:controls].any? { |x| x[:id] == example[:id] }
      true
    else
      false
    end
  end

  def move_example_into_control(example, control)
    control[:results] ||= []
    example.delete(:id)
    example.delete(:profile_id)
    control[:results].push(example)
  end

  def format_example(example)
    super(example).tap do |res|
      res[:run_time]   = example.execution_result.run_time
      res[:start_time] = example.execution_result.started_at.to_s
    end
  end
end

class InspecRspecCli < InspecRspecJson # rubocop:disable Metrics/ClassLength
  RSpec::Core::Formatters.register self, :close

  COLORS = {
    'critical' => "\033[38;5;9m",
    'major'    => "\033[38;5;208m",
    'minor'    => "\033[0;36m",
    'failed'   => "\033[38;5;9m",
    'passed'   => "\033[38;5;41m",
    'skipped'  => "\033[38;5;247m",
    'reset'    => "\033[0m",
  }.freeze

  INDICATORS = {
    'critical' => '  ×  ',
    'major'    => '  ∅  ',
    'minor'    => '  ⊚  ',
    'failed'   => '  ×  ',
    'skipped'  => '  ↺  ',
    'passed'   => '  ✔  ',
    'unknown'  => '  ?  ',
    'empty'    => '     ',
    'small'    => '   ',
  }.freeze

  MULTI_TEST_CONTROL_SUMMARY_MAX_LEN = 60

  def initialize(*args)
    @current_control = nil
    @all_controls = []
    @profile_printed = false
    super(*args)
  end

  #
  # This method is called through the RSpec Formatter interface for every
  # example found in the test suite.
  #
  # Within #format_example we are getting and example and:
  #    * if this is an example, within a control, within a profile then we want
  #      to display the profile header, display the control, and then display
  #      the example.
  #    * if this is another example, within the same control, within the same
  #      profile we want to display the example.
  #    * if this is an example that does not map to a control (anonymous) then
  #      we want to store it for later to displayed at the end of a profile.
  #
  def format_example(example)
    example_data = super(example)

    control = create_or_find_control(example_data)

    # If we are switching to a new control then we want to print the control
    # we were previously collecting examples unless the last control is
    # anonymous (no control). Anonymous controls and their examples are handled
    # later on the profile change.

    if switching_to_new_control?(control)
      print_last_control_with_examples unless last_control_is_anonymous?
    end

    store_last_control(control)

    # Each profile may have zero or more anonymous examples. These are examples
    # that defined in a profile but outside of a control. They may be defined
    # at the start, in-between, or end of list of examples. To display them
    # at the very end of a profile, which means we have to wait for the profile
    # to change to know we are done with a profile.

    if switching_to_new_profile?(control.profile)
      output.puts('')
      print_anonymous_examples_associated_with_last_profile
      clear_anonymous_examples_associated_with_last_profile
    end

    print_profile(control.profile)
    store_last_profile(control.profile)

    # The anonymous controls should be added to a hash that we will display
    # when we are done examining all the examples within this profile.

    if control.anonymous?
      add_anonymous_example_within_this_profile(control.as_hash)
    end

    @all_controls.push(control.as_hash)
    example_data
  end

  #
  # This is the last method is invoked through the formatter interface.
  # Because the profile
  # we may have some remaining anonymous examples so we want to display them
  # as well as a summary of the profile and test stats.
  #
  def close(_notification)
    print_last_control_with_examples
    output.puts('')
    print_anonymous_examples_associated_with_last_profile
    output.puts('')
    print_profile_summary
    print_tests_summary
  end

  private

  #
  # With the example we can find the profile associated with it and if there
  # is already a control defined. If there is one then we will use that data
  # to build our control object. If there isn't we simply create a new hash of
  # controld data that will be populated from the examples that are found.
  #
  # @return [Control] A new control or one found associated with the example.
  #
  def create_or_find_control(example)
    profile = profile_from_example(example)

    control_data = {}

    if profile && profile[:controls]
      control_data = profile[:controls].find { |ctrl| ctrl[:id] == example[:id] }
    end

    control = Control.new(control_data, profile)
    control.add_example(example)

    control
  end

  #
  # If there is already a control we have have seen before and it is different
  # than the new control then we are indeed switching controls.
  #
  def switching_to_new_control?(control)
    @last_control && @last_control.id != control.id
  end

  def store_last_control(control)
    @last_control = control
  end

  def print_last_control_with_examples
    print_control(@last_control)
    @last_control.examples.each { |example| print_result(example) }
  end

  def last_control_is_anonymous?
    @last_control.anonymous?
  end

  #
  # If there is a profile we have seen before and it is different than the
  # new profile then we are indeed switching profiles.
  #
  def switching_to_new_profile?(new_profile)
    @last_profile && @last_profile != new_profile
  end

  #
  # Print all the anonymous examples that have been found for this profile
  #
  def print_anonymous_examples_associated_with_last_profile
    Array(anonymous_examples_within_this_profile).uniq.each do |control|
      print_anonymous_control(control)
    end
  end

  #
  # As we process examples we need an accumulator that will allow us to store
  # all the examples that do not have a named control associated with them.
  #
  def anonymous_examples_within_this_profile
    @anonymous_examples_within_this_profile ||= []
  end

  #
  # Remove all controls from the anonymous examples that are tracked.
  #
  def clear_anonymous_examples_associated_with_last_profile
    @anonymous_examples_within_this_profile = []
  end

  #
  # Append a new control to the anonymous examples
  #
  def add_anonymous_example_within_this_profile(control)
    anonymous_examples_within_this_profile.push(control)
  end

  def store_last_profile(new_profile)
    @last_profile = new_profile
  end

  #
  # Print the profile
  #
  #   * For anonymous profiles, where are generated for examples and controls
  #     defined outside of a profile, simply display the target information
  #   * For profiles without a title use the name (or 'unknown'), version,
  #     and target information.
  #   * For all other profiles display the title with name (or 'unknown'),
  #     version, and target information.
  #
  def print_profile(profile)
    return if profile[:already_printed]
    output.puts ''

    if profile[:name].nil?
      print_target
      profile[:already_printed] = true
      return
    end

    if profile[:title].nil?
      output.puts "Profile: #{profile[:name] || 'unknown'}"
    else
      output.puts "Profile: #{profile[:title]} (#{profile[:name] || 'unknown'})"
    end

    output.puts 'Version: ' + (profile[:version] || 'unknown')
    print_target
    profile[:already_printed] = true
  end

  #
  # This target information displays which system that came under test
  #
  def print_target
    return if @backend.nil?
    connection = @backend.backend
    return unless connection.respond_to?(:uri)
    output.puts('Target:  ' + connection.uri + "\n\n")
  end

  #
  # We want to print the details about the control
  #
  def print_control(control)
    print_line(
      color:      COLORS[control.summary_indicator] || '',
      indicator:  INDICATORS[control.summary_indicator] || INDICATORS['unknown'],
      summary:    format_lines(control.summary, INDICATORS['empty']),
      id:         "#{control.id}: ",
      profile:    control.profile_id,
    )
  end

  def print_result(result)
    test_status = result[:status_type]
    test_color = COLORS[test_status]
    indicator = INDICATORS[result[:status]]
    indicator = INDICATORS['empty'] if indicator.nil?
    if result[:message]
      msg = result[:code_desc] + "\n" + result[:message]
    else
      msg = result[:skip_message] || result[:code_desc]
    end
    print_line(
      color:      test_color,
      indicator:  INDICATORS['small'] + indicator,
      summary:    format_lines(msg, INDICATORS['empty']),
      id: nil, profile: nil
    )
  end

  def print_anonymous_control(control)
    control_result = control[:results]
    title = control_result[0][:code_desc].split[0..1].join(' ')
    puts '  ' + title
    # iterate over all describe blocks in anonoymous control block
    control_result.each do |test|
      control_id = ''
      # display exceptions
      unless test[:exception].nil?
        test_result = test[:message]
      else
        # determine title
        test_result = test[:skip_message] || test[:code_desc].split[2..-1].join(' ')
        # show error message
        test_result += "\n" + test[:message] unless test[:message].nil?
      end
      status_indicator = test[:status_type]
      print_line(
        color:      COLORS[status_indicator] || '',
        indicator:  INDICATORS['small'] + INDICATORS[status_indicator] || INDICATORS['unknown'],
        summary:    format_lines(test_result, INDICATORS['empty']),
        id:         control_id,
        profile:    control[:profile_id],
      )
    end
  end

  def print_profile_summary
    summary = profile_summary

    s = format('Profile Summary: %s%d successful%s, %s%d failures%s, %s%d skipped%s',
               COLORS['passed'], summary['passed'], COLORS['reset'],
               COLORS['failed'], summary['failed']['total'], COLORS['reset'],
               COLORS['skipped'], summary['skipped'], COLORS['reset'])
    output.puts(s) if summary['total'] > 0
  end

  def print_tests_summary
    summary = tests_summary

    s = format('Test Summary: %s%d successful%s, %s%d failures%s, %s%d skipped%s',
               COLORS['passed'], summary['passed'], COLORS['reset'],
               COLORS['failed'], summary['failed'], COLORS['reset'],
               COLORS['skipped'], summary['skipped'], COLORS['reset'])
    output.puts(s)
  end

  # Formats the line (called from print_line)
  def format_line(fields)
    format = '%color%indicator%id%summary'
    format.gsub(/%\w+/) do |x|
      term = x[1..-1]
      fields.key?(term.to_sym) ? fields[term.to_sym].to_s : x
    end + COLORS['reset']
  end

  # Prints line; used to print results
  def print_line(fields)
    output.puts(format_line(fields))
  end

  # Helps formatting summary lines (called from within print_line arguments)
  def format_lines(lines, indentation)
    lines.gsub(/\n/, "\n" + indentation)
  end

  #
  # This class wraps a control hash object to provide a useful inteface for
  # maintaining the associated profile, ids, results, title, etc.
  #
  class Control
    STATUS_TYPES = {
      'unknown'  => -3,
      'passed'   => -2,
      'skipped'  => -1,
      'minor'    => 1,
      'major'    => 2,
      'failed'   => 2.5,
      'critical' => 3,
    }.freeze

    def initialize(control, profile)
      @control = control
      @profile = profile
      @summary_indicator = STATUS_TYPES['unknown']
      @skips = []
      @fails = []
      @passes = []
    end

    attr_reader :control, :profile

    alias as_hash control

    attr_reader :skips, :fails, :passes, :summary_indicator

    def id
      control[:id]
    end

    #
    # Adds an example to the control. This example
    def add_example(example)
      control[:id] = example[:id]
      control[:profile_id] = example[:profile_id]

      example[:status_type] = status_type(example)
      example.delete(:id)
      example.delete(:profile_id)

      control[:results] ||= []
      control[:results].push(example)
      update_results(example)
    end

    # Determines 'status_type' (critical, major, minor) of control given
    # status (failed/passed/skipped) and impact value (0.0 - 1.0).
    # Called from format_example, sets the 'status_type' for each 'example'
    def status_type(example)
      status = example[:status]
      return status if status != 'failed' || control[:impact].nil?
      if control[:impact] >= 0.7
        'critical'
      elsif control[:impact] >= 0.4
        'major'
      else
        'minor'
      end
    end

    def anonymous?
      control[:id].to_s.start_with? '(generated from '
    end

    def profile_id
      control[:profile_id]
    end

    def examples
      control[:results]
    end

    def update_results(example)
      summary_status = STATUS_TYPES[example[:status_type]]
      @summary_indicator = STATUS_TYPES.key(summary_status) if summary_status > summary_indicator
      fails.push(example) if summary_status > 0
      passes.push(example) if summary_status == STATUS_TYPES['passed']
      skips.push(example) if summary_status == STATUS_TYPES['skipped']
    end

    # Determine title for control given current_control.
    # Called from current_control_summary.
    def title
      title = control[:title]
      res = control[:results]
      if title
        title
      elsif res.length == 1
        # If it's an anonymous control, just go with the only description
        # available for the underlying test.
        res[0][:code_desc].to_s
      elsif res.length.empty?
        # Empty control block - if it's anonymous, there's nothing we can do.
        # Is this case even possible?
        'Empty anonymous control'
      else
        # Multiple tests - but no title. Do our best and generate some form of
        # identifier or label or name.
        title = (res.map { |r| r[:code_desc] }).join('; ')
        max_len = MULTI_TEST_CONTROL_SUMMARY_MAX_LEN
        title = title[0..(max_len-1)] + '...' if title.length > max_len
        title
      end
    end

    # Return summary of the control which is usually a title with fails and skips
    def summary
      res = control[:results]
      suffix =
        if res.length == 1
          # Single test - be nice and just print the exception message if the test
          # failed. No need to say "1 failed".
          res[0][:message].to_s
        else
          [
            !fails.empty? ? "#{fails.length} failed" : nil,
            !skips.empty? ? "#{skips.length} skipped" : nil,
          ].compact.join(' ')
        end
      if suffix == ''
        title
      else
        title + ' (' + suffix + ')'
      end
    end
  end
end

class InspecRspecJUnit < RSpecJUnitFormatter
  RSpec::Core::Formatters.register self, :close

  def initialize(*args)
    super(*args)
  end

  def close(_notification)
  end
end
