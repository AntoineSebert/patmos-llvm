#
# PSK Toolchain
#
# Generate trace using pasim and extract flow facts (underapproximations)
#
# A word on performance; Currently we have (buildbot, adpcm -O0):
#  pasim >/dev/null .. 18s
#  read from pasim  .. 1m39
#  read and parse   .. 1m52
#  psk-analyze-trace .. 2m
# So there is probably not a lot to optimize in the ruby logic.
#
# Nevertheless, for this tool it might be worth to think of a faster solution;
# it seems as if the pipe communication the cuprit.

require 'utils'
include PML

# Class to (lazily) read pasim simulator trace
class SimulatorTrace
  def initialize(elf,pasim)
    @elf,@pasim = elf,pasim
  end
  def each
    die("Executable #{@pasim} not found") unless File.executable?(`which #{@pasim}`.chomp)
    IO.popen("pasim -q --debug 0 --debug-fmt trace -b #{@elf} 2>&1 1>/dev/null") do |io|
      while item=parse(io.gets) ; yield item ; end
    end
  end
  def parse(line)
    return nil unless line
    pc, cyc = line.split(' ',2)
    [ Integer("0x#{pc}"), Integer(cyc) ]
  end
end

# Class to monitor trace and generate events
class TraceMonitor
  DELAY_SLOTS = 2
  def initialize(elf,pml,pasim,program_start = "main")
    @pml = pml
    @trace = SimulatorTrace.new(elf,pasim)
    @program_entry = @pml.machine_functions.by_label(program_start)
    @start = @program_entry.blocks.first.address
    @observers = []
    # whether an instruction is a watch point
    @wp = {}
    # basic block watch points
    @wp_block_start = {}
    # call instruction watch points
    @wp_call_instr = {}
    # instructions which the callee returns to
    @wp_callreturn_instr = {}
    # return instruction watch points
    @wp_return_instr = {}
    build_watchpoints
  end

  def subscribe(obj)
    @observers.push(obj)
  end

  def run
    @executed_instructions = 0
    callstack, last_call = [], nil
    current_function, loopstack = nil, nil

    @trace.each do |pc,cycles|

      @started = true if pc == @start
      next unless @started

      @executed_instructions += 1
      next unless @wp[pc]
      
      # Handle Basic Block
      if b = @wp_block_start[pc]
        # function entry
        if b.address == b.function.address
          # call
          if last_call
            c, call_time = last_call
            assert("No call instruction before function entry") { call_time + 1 + DELAY_SLOTS == @executed_instructions }
            callstack.push(c)
            last_call = nil
          else
            assert("Empty call history at function entry, but not main function") { b.function == @program_entry }
          end
          current_function = b.function
          loopstack = []
          publish(:function, b.function, callstack[-1], cycles) 
        end
        # loop exit
        while b.loopnest < loopstack.length
          publish(:loopexit, loopstack.pop, cycles)
        end
        # loop header
        if b.loopheader?
          if b.loopnest == loopstack.length && loopstack[-1].name != b.name
            publish(:loopexit, loopstack.pop, cycles)
          end
          if b.loopnest == loopstack.length
            publish(:loopcont, b, cycles)
          else
            loopstack.push b
            publish(:loopenter, b, cycles)
          end
        end
        # basic block
        assert("Current function does not match block: #{current_function} != #{b}") { current_function == b.function }
        publish(:block, b, cycles)
      end

      # Handle Call
      if c = @wp_call_instr[pc]
        last_call = [c, @executed_instructions]
      end

      # Handle Return Block (TODO: in order to handle predicated returns, we need to know where return instructions are)
      if r = @wp_return_instr[pc]
        if callstack.empty? 
          publish(:ret, r, nil, cycles)
        else
          publish(:ret, r, callstack[-1], cycles)
        end
        break if(r.function == @program_entry)
        assert("Callstack empty at return (inconsistent callstack)") { ! callstack.empty? }
        c = callstack.pop
        loopstack = c.block.loops.reverse
        current_function = c.function
      end

    end

    publish(:eof)
  end

  def publish(msg,*args)
    @observers.each do |obs|
      obs.send(msg,*args)
    end
  end

  private
  def build_watchpoints
    # generate watchpoints for all relevant machine functions
    @pml.machine_functions.each do |fun|
      # address of function
      addr = fun.address
      abs_instr_index = 0
      call_return_instr = {}

      # for all basic blocks
      fun.blocks.each do |block|

        # generate basic block event at first instruction
        add_watch(@wp_block_start, block.address, block)

        # generate return event at return instruction
        # FIXME: does not work for predicated return instructions now,
        # it would be helpful if return instructions where marked in PML
        if block.successors.empty?
          return_ins = block.instructions[-1-DELAY_SLOTS]
          add_watch(@wp_return_instr,return_ins['address'],return_ins)
        end

        block.instructions.each do |instruction|
          if call_return_instr[abs_instr_index]
            add_watch(@wp_callreturn_instr,instruction['address'],instruction)
          end
          if ! (instruction['callees']||[]).empty?
            add_watch(@wp_call_instr,instruction['address'],instruction)
            call_return_instr[abs_instr_index+1+DELAY_SLOTS]=true
          end
          abs_instr_index += 1
        end
      end
    end
  end
  def add_watch(dict,addr,data)
    if ! addr
      warn ("No address for #{data.inspect[0..60]}")
    elsif dict[addr]
      raise Exception.new("Duplicate watchpoint at address #{addr.inspect}: #{data} / #{dict[addr]}")
    else
      @wp[addr] = true
      dict[addr] = data
    end
  end
end

class VerboseRecorder
  def initialize(out=$>)
    @out = out
  end
  def method_missing(event, *args)
    @out.puts("EVENT #{event.to_s.ljust(15)} #{args.join(" ")}")
  end
end

class GlobalRecorder
  attr_reader :results
  def initialize(start_mf)
    @start_name = start_mf.name
    @results = FrequencyRecord.new("GlobalRecorder(#{start_mf})")
  end
  def function(callee,callsite,cycles)
    results.start(cycles) if callee['name']==@start_name
    results.call(callsite,callee)
  end
  def block(mbb, _)
    results.increment(mbb)
  end
  def ret(rsite,csite,cycles)
    results.stop(cycles) if(rsite.function.name==@start_name)
  end
  def eof ; end
  def method_missing(event, *args); end
end
class LoopRecorder
  attr_reader :results
  def initialize(start_mf)
    @start_name = start_mf.name
    @started = false
    @results = {}
  end
  def function(callee,callsite,cycles)
    @started = true if callee['name']==@start_name
  end
  def ret(rsite,csite,cycles)
    @started = false if rsite.function.name==@start_name
  end
  def loopenter(bb, cycles)
    results[bb] = FrequencyRecord.new("LoopRecorder(#{bb})") unless results[bb]
    results[bb].start(cycles)
    results[bb].increment(bb)
  end
  def loopcont(bb, _)
    results[bb].increment(bb)
  end
  def loopexit(bb, cycles)
    results[bb].stop(cycles)
  end
  def eof ; end
  def method_missing(event, *args); end
end

# Utility class to record frequencies when analyzing traces
class FrequencyRecord
  attr_reader :cycles, :freqs, :calltargets
  def initialize(name)
    @name = name
    @calltargets = {}
  end
  def start(cycles)
    @cycles_start = cycles
    @current_record = Hash.new(0)
  end
  def increment(bb)
    @current_record[bb] += 1 if @current_record
  end
  def call(callsite,callee)
    (@calltargets[callsite]||=Set.new).add(callee) if @current_record && callsite
  end
  def stop(cycles)
    die "Recorder: stop without start: #{@name}" unless @current_record
    @cycles = merge_ranges(cycles - @cycles_start, @cycles)
    unless @freqs
      @freqs = {}
      @current_record.each do |bref,count|
        @freqs[bref] = count .. count
      end
    else
      @current_record.each do |bref,count|
        if ! @freqs.include?(bref)
          @freqs[bref] = 0 .. count
        else
          @freqs[bref] = merge_ranges(count, @freqs[bref])
        end
      end
      @freqs.each do |bref,count|
        @freqs[bref] = merge_ranges(count, 0..0) unless @current_record.include?(bref)
      end
    end
    @current_record = nil
  end
  def dump(io=$>)
    (io.puts "No records";return) unless @freqs
    io.puts "---"
    io.puts "cycles: #{cycles}"
    @freqs.keys.sort.each do |bref|
      io.puts "  #{bref.to_s.ljust(15)} \\in #{@freqs[bref]}"
    end
    @calltargets.each do |site,recv|
      io.puts "  #{site} calls #{recv.to_a.join(", ")}"
    end
  end
end

class AnalyzeTraceTool
  def AnalyzeTraceTool.add_options(opts,options)

# TODO: analysis entry != trace entry (think: running N tests invoking measure vs. frequencies relative to measure)
#    opts.on("--trace-entry FUNCTION", "Name of the program entry to be traced") { |f| options.trace_entry = f }

    opts.on("-e", "--analysis-entry FUNCTION", "Name of the function to analyse") { |f| options.analysis_entry = f }
    opts.on("--pasim-command FILE", "path to pasim (=pasim)") { |f| options.pasim = f }
  end

  # elf ... patmos ELF
  # pml ... PML for the prgoam
  # options.pasim ... path to pasim executable
  def AnalyzeTraceTool.run(elf,pml,options)
    options.pasim = "pasim"           unless options.pasim
    options.trace_entry = "main"      unless options.trace_entry
    options.analysis_entry = "main"   unless options.analysis_entry

    tm = TraceMonitor.new(elf,pml,options.pasim)
    tm.subscribe(VerboseRecorder.new($dbgs)) if options.debug
    entry  = pml.machine_functions.by_label(options.analysis_entry)
    global = GlobalRecorder.new(entry)
    loops  = LoopRecorder.new(entry)
    tm.subscribe(global)
    tm.subscribe(loops)
    tm.run

    # Collect executed and infeasible blocks
    executed_blocks = {}
    infeasible_blocks = Set.new
    global.results.freqs.each do |block,freq|
      bset = (executed_blocks[block.function] ||= Set.new)
      bset.add(block)
    end
    executed_blocks.each do |function, covered|
      function.blocks.each do |block|
        unless covered.include?(block)
          infeasible_blocks.add(block)
        end
      end
    end

    if options.verbose
      $dbgs.puts "Global Frequencies"
      global.results.dump($dbgs)
      puts "Loop Bounds"
      loops.results.values.each { |r| r.dump($dbgs) }
      $dbgs.puts "Executed Functions: #{executed_blocks.keys.join(", ")}"
    end

    fact_context = { 'level' => 'machinecode', 'origin' => 'trace'}
    globalscope = entry.ref

    pml.add_timing(TimingEntry.new(globalscope,global.results.cycles.max,fact_context))

    # Export global block frequencies, call targets and infeasible blocks
    global.results.freqs.each do |block,freq|
      pml.flowfacts.add(FlowFact.block_frequency(globalscope, block, freq, fact_context, "block-global"))
    end
    global.results.calltargets.each do |cs,receiverset|
      next unless cs['callees'].include?('__any__')
      pml.flowfacts.add(FlowFact.calltargets(globalscope, cs, receiverset, fact_context, "calltargets-global"))
    end
    infeasible_blocks.each do |block|
      pml.flowfacts.add(FlowFact.block_frequency(globalscope, block, 0..0, fact_context, "infeasible-global"))
    end

    # Export Loops
    loops.results.values.each do |loopbound|
      loop,freq = loopbound.freqs.to_a[0]
      pml.flowfacts.add(FlowFact.block_frequency(loop.loopref, loop, freq, fact_context, "loop-local"))
    end
    executed_blocks.each do |function,bset|
      function.loops.each do |block|
        unless bset.include?(block)
          warn "Loop #{block} not executed by trace"
          pml.flowfacts.add(FlowFact.block_frequency(block.loopref, block, 0..0, fact_context, "loop-local"))
        end
      end
    end

    pml
  end
end

if __FILE__ == $0
SYNOPSIS=<<EOF
Generate flow facts reflecting frequencies from machine-code
execution traces generated with 'pasim --debug'.
Also adds observed receivers to indirect calls callee field.
EOF

  options, args = PML::optparse(1..1, "program.elf", SYNOPSIS, :type => :io) do |opts,options|
    AnalyzeTraceTool.add_options(opts,options)
  end
  AnalyzeTraceTool.run(args.first, PMLDoc.from_file(options.input), options).dump_to_file(options.output)
end
