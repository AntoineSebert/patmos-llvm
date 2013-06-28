#
# PLATIN tool set
#
# trace analysis (similar to SWEET single path mode)
#
require 'core/utils'
require 'core/pml'
require 'core/context'

module PML

# Class to monitor traces and generate events
# should implement a 'run' method
class TraceMonitor
  attr_reader :observers
  def initialize
    @observers = []
  end
  def subscribe(obj)
    @observers.push(obj)
  end
  def publish(msg,*args)
    @observers.each do |obs|
      obs.send(msg,*args)
    end
  end
end

#
# Class to monitor machine trace and generate events
#
# Traces need to be of the form [programcounter, cycles]
# Generated events: block, function, ret, loop{enter,exit,cont}, eof
#
class MachineTraceMonitor < TraceMonitor
  def initialize(pml, options, trace)
    super()
    @pml, @options = pml, options
    @trace = trace
    @program_entry = @pml.machine_functions.by_label(options.trace_entry)
    @start = @program_entry.blocks.first.address
    # whether an instruction is a watch point
    @wp = {}
    # basic block watch points
    @wp_block_start = {}
    # call instruction watch points
    @wp_call_instr = {}
    # return instruction watch points
    @wp_return_instr = {}
    # empty (zero-size) blocks before the key'ed block
    @empty_blocks = {}
    # Playground: Learn about instruction costs
    # @wp_instr = {}
    build_watchpoints
  end
  # run monitor
  def run
    @executed_instructions = 0
    @callstack = []
    @loopstack = nil
    @current_function = nil
    @last_block = nil
    @last_ins  = [nil,0] # XXX: playing
    @inscost   = {}  # XXX: playing
    pending_return, pending_call = nil, nil
    @trace.each do |pc,cycles|

      @started = true if pc == @start
      next unless @started

      @executed_instructions += 1

      # Playground: Learn about instruction costs
      # @inscost[@last_ins.first] = merge_ranges(cycles - @last_ins[1],@inscost[@last_ins.first]) if @last_ins.first
      # @last_ins = [@wp_instr[pc],cycles]
      # debug(@options, :trace) { "pc: #{pc} [t=#{cycles}]" }

      next unless @wp[pc] || pending_return

      @cycles = cycles
      # Handle Return (TODO)
      if pending_return && pending_return[1] + @pml.arch.return_delay_slots + 1 == @executed_instructions
        # debug(@options, :trace) { "Return from #{pending_return.first} -> #{@callstack[-1]}" }
        # If we there was no change of control-flow since the return instruction,  the pending return
        # was not executed (predicated). This is a heuristic, and should not be used for simulators
        # with better information available (it fails if the recursive function returns to next instruction,
        # which is unlikely, but possible)
        fallthrough_instruction = pending_return.first
        (@pml.arch.return_delay_slots+1).times do
          fallthrough_instruction = fallthrough_instruction.next
          break unless fallthrough_instruction
        end
        if fallthrough_instruction && pc == fallthrough_instruction.address
          # debug(@options, :trace) { "Predicated return at #{fallthrough_instruction}" }
        else
          if ! handle_return(*pending_return)
            @inscost.each do |op,cycs|
              puts "COST #{op} #{cycs}"
            end
            break
          end
          pending_return = nil
        end
      end

      # Handle Basic Block
      if b = @wp_block_start[pc]
        # debug(@options, :trace) { "#{pc}: Block: #{b} / #{b.address}" }
        # function entry
        if b.address == b.function.address
          # call
          if pending_call
            handle_call(*pending_call) if pending_call
            #puts "Call: #{pending_call.first} -> #{b.function}"
            pending_call = nil
          else
            assert("Empty call history at function entry, but not main function (#{b.function},#{@program_entry})") {
              b.function == @program_entry
            }
          end

          # set current function
          @current_function = b.function
          # debug(@options, :trace) { "change function to #{b.function}" }
          @loopstack = []
          publish(:function, b.function, @callstack[-1], @cycles)
        end

        # loop exit
        exit_loops_downto(b.loopnest)

        # loop header
        handle_loopheader(b)

        # basic block
        assert("Current function does not match block: #{@current_function} != #{b}") { @current_function == b.function }

        # Empty blocks are problematic (cannot be distinguished) - what do do?
        # They are rare (only with -O0), so we tolerate some work. An empty block
        # is published only if it is a successor of the last block
        @empty_blocks[b.address].each { |b0|
          if ! @last_block || @last_block.successors.include?(b0)
            while(b0.instructions.size == 0)
              debug(@options,:trace) { "Publishing empty block #{b0} (<-#{@last_block})" }
              publish(:block, b0, @cycles)
              assert("Empty block may only have one successor") { b0.successors.size == 1}
              @last_block = b0
              b0 = @last_block.successors.first
            end
            break
          end
        } if @empty_blocks[b.address]
        publish(:block, b, @cycles)
        @last_block = b
      end

      # Handle Call
      if c = @wp_call_instr[pc]
        assert("Call instruction #{c} does not match current function #{@current_function}") {
          c.function == @current_function
        }
        pending_call = [c, @executed_instructions]
        # debug(@options, :trace) { "#{pc}: Call: #{c} in #{@current_function}" }
      end

      # Handle Return Block
      # TODO: in order to handle predicated returns, we need to know where return instructions ar
      if r = @wp_return_instr[pc]
        pending_return = [r,@executed_instructions]
        # debug(@options, :trace) { "Scheduling return at #{r}" }
      end
    end

    publish(:eof)
  end

  private

  def handle_loopheader(b)
    if b.loopheader?
      if b.loopnest == @loopstack.length && @loopstack[-1].name != b.name
        publish(:loopexit, @loopstack.pop, @cycles)
      end
      if b.loopnest == @loopstack.length
        publish(:loopcont, b, @cycles)
      else
        @loopstack.push b
        publish(:loopenter, b, @cycles)
      end
    end
  end

  def handle_call(c, call_pc)
    assert("No call instruction before function entry #{call_pc + 1 + @pml.arch.call_delay_slots} != #{@executed_instructions}") {
      call_pc + 1 + @pml.arch.call_delay_slots == @executed_instructions
    }
    @lastblock = nil
    @callstack.push(c)
    # debug(@options, :trace) { "Call from #{@callstack.inspect}" }
  end

  def handle_return(r, ret_pc)
    exit_loops_downto(0)
    if @callstack.empty?
      publish(:ret, r, nil, @cycles)
    else
      publish(:ret, r, @callstack[-1], @cycles)
    end
    return nil if(r.function == @program_entry)
    assert("Callstack empty at return (inconsistent callstack)") { ! @callstack.empty? }
    c = @callstack.pop
    @last_block = c.block
    @loopstack = c.block.loops.reverse
    @current_function = c.function
    # debug(@options, :trace) { "Return to #{c}" }
  end

  def exit_loops_downto(nest)
    while nest < @loopstack.length
      publish(:loopexit, @loopstack.pop, @cycles)
    end
  end

  def build_watchpoints
    # generate watchpoints for all relevant machine functions
    @pml.machine_functions.each do |fun|
      # address of function
      addr = fun.address
      abs_instr_index = 0
      call_return_instr = {}

      # for all basic blocks
      fun.blocks.each do |block|

        # blocks that consist of labels only (used in some benchmarks for flow facts)
        if block.empty?
          (@empty_blocks[block.address]||=[]).push(block)
          next
        end

        # generate basic block event at first instruction
        add_watch(@wp_block_start, block.address, block)

        block.instructions.each do |instruction|
          # Playground: Learn about instruction costs
          # @wp_instr[instruction.address] = instruction

          # trigger return-instruction event at return instruction
          # CAVEAT: delay slots and predicated returns
          if instruction.returns?
            add_watch(@wp_return_instr,instruction.address,instruction)
          end
          # trigger call-instruction event at call instructions
          # CAVEAT: delay slots and predicated calls
          if ! instruction.callees.empty?
            add_watch(@wp_call_instr,instruction['address'],instruction)
          end
          abs_instr_index += 1
        end
      end
    end
  end
  def add_watch(dict, addr, data)
    if ! addr
      warn ("No address for #{data.inspect[0..60]}")
    elsif dict[addr]
      raise Exception.new("Duplicate watchpoint at address #{addr.inspect}: #{data} already set to #{dict[addr]}")
    else
      @wp[addr] = true
      dict[addr] = data
    end
  end
end

# Recorder which just dumps event to the given stream
class VerboseRecorder
  def initialize(out=$>)
    @out = out
  end
  def method_missing(event, *args)
    @out.puts("EVENT #{event.to_s.ljust(15)} #{args.join(" ")}")
  end
end

# Recorder Specifications
class RecorderSpecification
  SPEC_RE = %r{ \A
                ([gf])
                (?: / ([0-9]+))?
                :
                ([blic]+)
                (?: / ([0-9]+))?
                \Z }x
  SCOPES = { 'g' => :global, 'f' => :function }
  ENTITIES = { 'b' => :block_frequencies, 'i' => :infeasible_blocks, 'l' => :loop_header_bounds, 'c' => :call_targets }
  attr_reader :entity_types, :entity_context, :calllimit
  def initialize(entity_types, entity_context, calllimit)
    @entity_types, @entity_context, @calllimit = entity_types, entity_context, calllimit
  end

  def RecorderSpecification.help(out=$stderr)
    out.puts("spec              := <spec-item>,...")
    out.puts("spec-item         := <scope-selection> ':' <entity-selection> [ ':' <calledepth-limit> ]")
    out.puts("scope-selection   :=   'g' (=analysis-entry-scope)")
    out.puts("                     | 'f'['/' <callstring-length>] (=function-scopes)")
    out.puts("entity-selection  := <entity-type>+ [ '/' <callstring-length> ]")
    out.puts("entity-type       :=   'b' (=block frequencies)")
    out.puts("                     | 'i' (=infeasible blocks)")
    out.puts("                     | 'l' (=loop bounds)")
    out.puts("                     | 'c' (=indirect call targets)")
    out.puts("entity-filter     := <calldepth-limit>")
    out.puts("callstring-length := <integer>")
    out.puts("calldepth-limit   := <integer>")
    out.puts("")
    out.puts("Example: g:lc:1  ==> loop bounds and call targets in global scope using callstring length 1")
    out.puts("         g:b:0   ==> block frequencies in global scope (context insensitive)")
    out.puts("         f:b::0  ==> local block frequencies for every executed function (default virtual inlining treshold)")
  end
  def RecorderSpecification.parse(str, default_callstring_length)
    recorders = []
    str.split(/\s*,\s*/).each { |recspec|
      if recspec =~ SPEC_RE
        scopestr,scopectx,etypes,ectx,elimit = $1,$2,$3,$4,$5
        entity_types = etypes.scan(/./).map { |etype|
          ENTITIES[etype] or die("RecorderSpecification '#{recspec}': Unknown entity type #{etype}")
        }
        entity_context = ectx ? ectx.to_i : default_callstring_length
        scope_context = scopectx ? scopectx.to_i : default_callstring_length
        entity_call_limit = nil
        if scopestr == 'f' # intraprocedural
          entity_call_limit = entity_context
        end
        spec = RecorderSpecification.new(entity_types, entity_context, entity_call_limit)
        scope = SCOPES[scopestr] or die("Bad scope type #{scopestr}")
        recorders.push([scope,scope_context,spec])
      else
        die("Bad recorder Specfication '#{recspec}': does not match #{SPEC_RE}")
      end
    }
    recorders
  end
end

# Recorder that schedules other recorders
class RecorderScheduler
  attr_accessor :start, :runs, :executed_blocks
  def initialize(recorder_specs, analysis_entry)
    @start = analysis_entry
    @runs = 0
    @executed_blocks = {}
    @recorder_map = {}
    @global_specs, @function_specs = [], []
    recorder_specs.each { |type,ctx,spec|
      if type == :global
        @global_specs.push(spec)
      elsif type == :function
        @function_specs.push([ctx,spec])
      else
        die("RecorderScheduler: Bad recorder scope '#{type}'")
      end
    }
    @running = false
  end
  def recorders
    @recorder_map.values
  end
  def global_recorders
    recorders.select { |r| r.global? }
  end
  def function(callee,callsite,cycles)
    if @running
      # adjust callstack
      @callstack.push(callsite)
      # trigger active recorders
      @active.values.each { |recorder| recorder.function(callee,callsite,cycles) }
    end

    # start recording at analysis entry
    if callee['name'] == @start.name
      @running = true
      @runs += 1
      @active = {}
      @callstack = []
      # activate global recorders
      @global_specs.each_with_index do |gspec, tix|
        activate(:global, tix, callee, nil, gspec, cycles)
      end
    end

    # activate/create function recorders
    if @running
      # create/activate function recorders
      @function_specs.each_with_index do |fspec, tix|
        scopectx, recorder_spec = fspec
        activate(:function, tix, callee, BoundedStack.suffix(@callstack,scopectx), recorder_spec, cycles)
      end
    end
  end

  def activate(type, spec_id, scope_entity, scope_context, spec, cycles)
    key = [type, spec_id, scope_entity, scope_context]
    recorder = @recorder_map[key]
    if ! recorder
      rid = @recorder_map.size
      @recorder_map[key] = recorder = case type
                                   when :global;   FunctionRecorder.new(self, rid, scope_entity, scope_context, spec)
                                   when :function; FunctionRecorder.new(self, rid, scope_entity, scope_context, spec)
                                   end
    end
    @active[recorder.rid] = recorder
    recorder.start(scope_entity, cycles)
  end
  # NB: deactivate is called by the recorder
  def deactivate(recorder)
    @active.delete(recorder.rid)
  end
  def ret(rsite,csite,cycles)
    if @running
      @active.values.each { |recorder| recorder.ret(rsite,csite,cycles) }
      # stop if the callstack is empty
      if @callstack.empty?
        @running = false
      else
        @callstack.pop
      end
    end
  end
  def block(bb, cycles)
    return unless @running
    (@executed_blocks[bb.function] ||= Set.new).add(bb)
    @active.values.each { |recorder| recorder.block(bb, cycles) }
  end
  def loopenter(bb, cycles)
    return unless @running
    @active.values.each { |recorder| recorder.loopenter(bb, cycles) }
  end
  def loopcont(bb, cycles)
    return unless @running
    @active.values.each { |recorder| recorder.loopcont(bb, cycles) }
  end
  def loopexit(bb, cycles)
    return unless @running
    @active.values.each { |recorder| recorder.loopexit(bb, cycles) }
  end
  def eof ; end
  def method_missing(event, *args)
  end
end

# Recorder for a function (intra- or interprocedural)
class FunctionRecorder
  attr_reader :results, :rid, :report_block_frequencies
  def initialize(scheduler, rid, function, context, spec)
    @scheduler = scheduler
    @rid, @function, @context = rid, function, context
    @callstack, @calllimit = [], spec.calllimit
    @callstring_length = spec.entity_context
    @report_block_frequencies = spec.entity_types.include?(:block_frequencies)
    @record_block_frequencies = @report_block_frequencies || spec.entity_types.include?(:infeasible_blocks)
    @record_calltargets = spec.entity_types.include?(:call_targets)
    @record_loopheaders = spec.entity_types.include?(:loop_header_bounds)
    @results = FrequencyRecord.new("FunctionRecorder_#{rid}(#{function}, #{context || 'global'})")
  end
  def global?
    ! @context
  end
  def type
    global? ? 'global' : 'function'
  end
  def scope
    if @context
      FunctionRef.new(@function, CallString.from_bounded_stack(@context))
    else
      @function.ref
    end
  end
  def active?
    return true unless @calllimit
    @callstack.length <= @calllimit
  end
  def start(function, cycles)
    # puts "#{self}: starting at #{cycles}"
    results.start(cycles)
    @callstack = []
    function.blocks.each { |bb| results.init_block(in_context(bb)) }
  end
  def function(callee,callsite,cycles)
    results.call(in_context(callsite),callee) if active? && @record_calltargets
    @callstack.push(callsite)
    callee.blocks.each { |bb| results.init_block(in_context(bb)) } if active?
  end
  def block(bb, _)
    return unless active?
    # puts "#{self}: visiting #{bb} active:#{active?} calllimit:#{@calllimit}"
    results.increment_block(in_context(bb)) if @record_block_frequencies
  end
  def loopenter(bb, cycles)
    return unless active?
    results.start_loop(in_context(bb)) if @record_loopheaders
  end
  def loopcont(bb, _)
    return unless active?
    results.increment_loop(in_context(bb)) if @record_loopheaders
  end
  def loopexit(bb, _)
    return unless active?
    results.stop_loop(in_context(bb)) if @record_loopheaders
  end
  def ret(rsite,csite,cycles)
    if @callstack.length == 0
      # puts "#{self}: stopping at #{rsite}->#{csite}"
      results.stop(cycles)
      @scheduler.deactivate(self)
    else
      @callstack.pop
    end
  end
  def eof ; end
  def method_missing(event, *args); end
  def to_s
    results.name
  end
  def dump(io=$stdout)
    header = "Observations for #{self}\n  function: #{@function}"
    header += "\n  context: #{@context}" if @context && ! @context.empty?
    results.dump(io, header)
  end
private
  def in_context(block)
    [ block, BoundedStack.suffix(@callstack, @callstring_length) ]
  end
end

# Utility class to record frequencies when analyzing traces
class FrequencyRecord
  attr_reader :name, :runs, :cycles, :blockfreqs, :calltargets, :loopbounds
  def initialize(name)
    @name = name
    @runs = 0
    @calltargets = {}
    @loopbounds = {}
    @blockfreqs = nil
  end
  def start(cycles)
    @cycles_start = cycles
    @runs += 1
    @current_record = {}
    @current_loops = {}
  end
  def init_block(pp)
    @current_record[pp] ||= 0 if @current_record
  end
  def increment_block(pp)
    @current_record[pp] += 1 if @current_record
  end
  def start_loop(hpp)
    return unless @current_loops
    @current_loops[hpp] = 1
  end
  def increment_loop(hpp)
    return unless @current_loops
    @current_loops[hpp] += 1
  end
  def stop_loop(hpp)
    merge_loop_bound(hpp, @current_loops[hpp])
  end
  def to_s
    "FrequencyRecord{ name = #{@name} }"
  end
  def call(callsite,callee)
    (@calltargets[callsite]||=Set.new).add(callee) if @current_record && callsite
  end
  def stop(cycles)
    die "Recorder: stop without start: #{@name}" unless @current_record
    @cycles = merge_ranges(cycles - @cycles_start, @cycles)
    unless @blockfreqs
      @blockfreqs = {}
      @current_record.each do |bref,count|
        @blockfreqs[bref] = count .. count
      end
    else
      @current_record.each do |bref,count|
        if ! @blockfreqs.include?(bref)
          @blockfreqs[bref] = 0 .. count
        else
          @blockfreqs[bref] = merge_ranges(count, @blockfreqs[bref])
        end
      end
      @blockfreqs.each do |bref,count|
        @blockfreqs[bref] = merge_ranges(count, 0..0) unless @current_record.include?(bref)
      end
    end
    @current_record, @current_loops = nil, nil
  end
  def dump(io=$>, header=nil)
    (io.puts "No records";return) unless @blockfreqs
    io.puts "---"
    io.puts header if header
    io.puts "  cycles: #{cycles}"
    @blockfreqs.keys.sort.each do |bref|
      io.puts "  #{bref.to_s.ljust(15)} \\in #{@blockfreqs[bref]}"
    end
    @calltargets.each do |site,recv|
      io.puts "  #{site} calls #{recv.to_a.join(", ")}"
    end
    @loopbounds.each do |loop,bound|
      io.puts "  Loop #{loop} in #{bound}"
    end
  end
private
  def merge_loop_bound(key,bound)
    unless @loopbounds[key]
      @loopbounds[key] = bound..bound
    else
      @loopbounds[key] = merge_ranges(bound, @loopbounds[key])
    end
  end
end


# Records progress node trace
class ProgressTraceRecorder
  attr_reader :level, :trace, :internal_preds
  def initialize(pml, entry, is_machine_code, options)
    @pml, @options = pml, options
    @trace, @entry, @level = [], entry, is_machine_code ? :dst : :src
    @internal_preds, @pred_list = [], []
    @callstack = []
  end
  # set current relation graph
  # if there is no relation graph, skip function
  def function(callee,callsite,cycles)
    @rg = @pml.relation_graphs.by_name(callee.name, @level)
    debug(@options,:trace) { "Call to rg for #{@level}-#{callee}: #{@rg.nodes.first}" } if rg
    @callstack.push(@node)
    @node = nil
  end
  # follow relation graph, emit progress nodes
  def block(bb, _)
    return unless @rg
    if ! @node
      first_node = @rg.nodes.first
      assert("at_entry == at entry RG node") {
        first_node.type == :entry
      }
      assert("at_entry == at first block") {
        bb == first_node.get_block(level)
      }
      @node = first_node
      # debug(@options, :trace) { "Visiting first node: #{@node} (#{bb})" }
      return
    end
    # find matching successor progress node
    succs = @node.successors_matching(bb, @level)
    assert("progress trace: no (unique) successor (but #{succs.length}) at #{@node}, "+
           "following #{@node.get_block(@level)}->#{bb} (level #{@level})") {
      succs.length == 1
    }
    succ = succs.first
    if succ.type == :progress
      trace.push(succ)
      internal_preds.push(@pred_list)
      @pred_list = []
    else
      @pred_list.push(succ)
    end
    @node = succ
    # debug(@options,:trace) { "Visiting node: #{@node} (#{bb})" }
  end
  # set current relation graph
  def ret(rsite,csite,cycles)
    return if csite.nil?
    @rg = @pml.relation_graphs.by_name(csite.function.name, @level)
    @node = @callstack.pop
    debug(@options, :trace) { "Return to rg for #{@level}-#{csite.function}: #{@rg.nodes.first}" } if @rg
  end
  def eof ; end
  def method_missing(event, *args); end
end


end # module pml
