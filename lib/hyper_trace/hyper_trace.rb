class Class
  def hyper_trace(*args, &block)
    return unless React::IsomorphicHelpers.on_opal_client?
    HyperTrace.hyper_trace(self, *args, &block)
  end
  alias hypertrace hyper_trace
end

class Method
  def parameters
    /.*function[^(]*\(([^)]*)\)/
      .match(`#{@method}.toString()`)[1]
      .split(',')
      .collect { |param| [:req, param.strip.to_sym] }
  end
end

module HyperTrace

  class Config
    def initialize(klass, instrument_class, opts, &block)
      @klass = klass
      @opts = {}
      @instrument_class = instrument_class
      [:break_on_enter?, :break_on_entry?, :break_on_exit?, :break_on_enter, :break_on_entry, :break_on_exit, :instrument].each do |method|
        send(method, opts[method]) if opts[method]
      end unless opts[:instrument] == :none
      instance_eval(&block) if block
    end
    def instrument_class?
      @instrument_class
    end
    attr_reader :klass
    def instrument(opt)
      return if @opts[:instrument] == :all
      if opt == :all
        @opts[:instrument] = :all
      else
        @opts[:instrument] = [*opt, *@opts[:instrument]]
      end
    end
    def break_on_exit(methods)
      [*methods].each { |method| break_on_exit?(method) { true } }
    end
    def break_on_enter(methods)
      [*methods].each { |method| break_on_enter?(method) { true } }
    end
    alias break_on_entry break_on_enter
    def break_on_exit?(method, &block)
      @opts[:break_on_exit?] ||= {}
      @opts[:break_on_exit?][method] = block
      instrument(method)
    end
    def break_on_enter?(method, &block)
      @opts[:break_on_enter?] ||= {}
      @opts[:break_on_enter?][method] = block
      instrument(method)
    end
    alias break_on_entry? break_on_enter
    def [](opt)
      @opts[opt]
    end
    def hypertrace_class_exclusions
      if klass.respond_to? :hypertrace_class_exclusions
        klass.hypertrace_class_exclusions
      else
        []
      end
    end
    def hypertrace_exclusions
      if klass.respond_to? :hypertrace_exclusions
        klass.hypertrace_exclusions
      else
        []
      end
    end
  end


  class << self
    def hyper_trace(klass, *args, &block)
      if args.count == 0
        opts = { instrument: :all }
        instrument_class = false
      elsif args.first == :class
        opts = args[1] || {}
        instrument_class = true
      else
        opts = args.last || {}
        instrument_class = false
      end
      begin
        opts.is_a? Hash
      rescue Exception
        opts = Hash.new(opts)
      end
      config = Config.new(klass, instrument_class, opts, &block)
      if config[:exclude]
        exclusions[:instrumentation][klass] << opts[:exclude]
      else
        instrumentation_off(config)
        selected_methods = if config[:instrument] == :all
          all_methods(config)
        else
          Set.new config[:instrument]
        end
        selected_methods.each { |method| instrument_method(method, config) }
      end
    end

    def exclusions
      @exclusions ||= Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = Set.new } }
    end

    def instrumentation_off(config)
      if config.instrument_class?
        config.klass.methods.grep(/^__hyper_trace_pre_.+$/).each do |method|
          config.klass.class_eval do
            class << self
              alias_method method.gsub(/^__hyper_trace_pre_/, ''), method
            end
          end
        end
      else
        config.klass.instance_methods.grep(/^__hyper_trace_pre_.+$/).each do |method|
          config.klass.class_eval { alias_method method.gsub(/^__hyper_trace_pre_/, ''), method }
        end
      end
    end

    def all_methods(config)
      if config.instrument_class?
        Set.new(config.klass.methods.grep(/^(?!__hyper_trace_)/)) -
        Set.new(Class.methods + Object.methods) -
        config.hypertrace_class_exclusions -
        [:hypertrace_format_instance]
      else
        Set.new(config.klass.instance_methods.grep(/^(?!__hyper_trace_)/)) -
        Set.new(Class.methods + Object.methods) -
        config.hypertrace_exclusions -
        [:hypertrace_format_instance]
      end
    end

    def instrument_method(method, config)
      if config.instrument_class?
        config.klass.class_eval do
          class << self
            alias_method "__hyper_trace_pre_#{method}", method unless method_defined? "__pre_hyper_trace_#{method}"
          end
        end
        add_hyper_trace_method(method, config)
      else
        unless config.klass.method_defined? "__pre_hyper_trace_#{method}"
          config.klass.class_eval do
            alias_method "__hyper_trace_pre_#{method}", method
          end
        end
      end
      add_hyper_trace_method(method, config)
    end

    def formatting?
      @formatting
    end

    def safe_s(obj)
      obj.to_s
    rescue Exception
      "native object"
    end

    def safe_i(obj)
      "#{obj.inspect}"
    rescue Exception
      begin
        "native: #{`JSON.stringify(obj)`}"
      rescue Exception
        safe_s(obj)
      end
    end

    def show_js_object(obj)
      return true
      safe(obj) != obj
    rescue Exception
      nil
    end

    def instance_tag(instance, prefix = ' - ')
      if instance.instance_variables.any?
        "#{prefix}#<#{instance.class}:0x#{instance.object_id.to_s(16)}>"
      end
    end

    def format_head(instance, name, args)
      @formatting = true
      method = instance.method("__hyper_trace_pre_#{name}")
      if args.any?
        `console.group(#{" #{name}(...)#{instance_tag(instance)}"})`
        params = method.parameters
        `console.groupCollapsed(#{"args:"})`
        params.each_with_index do |param_spec, i|
          arg_name = param_spec[1]
          if arg_name == '$a_rest'
            arg_name = '*'
            arg = args[i..-1]
          else
            arg = args[i]
          end
          if safe_i(arg).length > 30 || show_js_object(arg)
            `console.groupCollapsed(#{"#{arg_name}: #{safe_s(arg)}"[0..29]})`
            puts safe_i(arg)
            `console.log(#{arg})` if show_js_object(arg)
          else
            `console.group(#{"#{arg_name}: #{safe_i(arg)}"})`
          end
          `console.groupEnd()`
        end
        `console.groupEnd()`
      else
        `console.group(#{" #{name}()#{instance_tag(instance)}"})`
      end
    ensure
      @formatting = false
    end

    def log(s)
      `console.log(#{s})`
    end

    def group(s, collapsed: false, &block)
      if collapsed
        `console.groupCollapsed(#{s})`
      else
        `console.group(#{s})`
      end
      yield if block
    ensure
      `console.groupEnd()`
    end

    def format_instance_internal(instance)
      return if @formatting
      @formatting = true
      if instance.respond_to? :hypertrace_format_instance
        instance.hypertrace_format_instance(self)
      else
        format_instance(instance, instance.instance_variables)
      end
    ensure
      @formatting = false
    end

    def format_instance(instance, filter = nil, &block)
      filtered_instance_variables = if filter
          filter
        else
          instance.instance_variables
        end
      return if filtered_instance_variables.empty? && block.nil?
      `console.groupCollapsed(#{"self:#{instance_tag(instance,' ')}"})`
      puts safe_i(instance) unless safe_i(instance).length < 40
      filtered_instance_variables.each do |iv|
        val = safe_i(instance.instance_variable_get(iv))
        `console.groupCollapsed(#{"#{iv}: #{val[0..10]}"})`
        puts val
        `console.log(#{instance.instance_variable_get(iv)})`
        `console.groupEnd()`
      end
      yield if block
      `console.groupEnd()`
    end

    def format_result(result)
      @formatting = true
      if safe_i(result).length > 40 || show_js_object(result)
        `console.groupCollapsed(#{"returns: #{safe_s(result)}"[0..40]})`
        puts safe_i(result)
        `console.log(#{result})` if show_js_object(result)
      else
        `console.group(#{"returns: #{safe_i(result)}"})`
      end
      `console.groupEnd()`
    ensure
      @formatting = false
    end

    def format_exception(result)
      @formatting = true
      if safe_i(result).length > 40
        `console.groupCollapsed(#{"raised: #{safe_s(result)}"[0..40]})`
        puts safe_i(result)
      else
        `console.group(#{"raised: #{safe_i(result)}"})`
      end
      `console.groupEnd()`
    ensure
      @formatting = false
    end

    def should_break?(location, config, name, args, instance, result)
      breaker = config["break_on_#{location}?"]
      breaker &&= breaker[name] || breaker[:all]
      return unless breaker
      args = [result, *args] if location == 'exit'
      @formatting = true
      instance.instance_exec(*args, &breaker)
    ensure
      @formatting = false
    end

    def breakpoint(location, config, name, args, instance, result = nil)
      if should_break? location, config, name, args, instance, result
        method = instance.method("__hyper_trace_pre_#{name}")
        fn_def = ['RESULT']
        fn_def += method.parameters.collect { |p| p[1] }
        fn_def += ["//break on #{location} of #{name}\nvar self = this;\ndebugger;\n;"]
        puts "break on #{location} of #{name}"
        fn = `Function.apply(#{self}, #{fn_def}).bind(#{instance})`
        fn.call(result, *args)
      end
    end

    def add_hyper_trace_method(method, config)
      def_method = config.instrument_class? ? :define_singleton_method : :define_method
      config.klass.send(def_method, method) do |*args, &block|
        block_string = ' { ... }' if block
        if HyperTrace.formatting?
          begin
            send "__hyper_trace_pre_#{method}", *args, &block
          rescue Exception
            "???"
          end
        else
          begin
            HyperTrace.format_head(self, method, args)
            HyperTrace.format_instance_internal(self)
            HyperTrace.breakpoint(:enter, config, method, args, self)
            result = send "__hyper_trace_pre_#{method}", *args, &block
            HyperTrace.format_result(result)
            HyperTrace.breakpoint(:exit, config, method, args, self, result)
            result
          rescue Exception => e
            HyperTrace.format_exception(e)
            debugger unless HyperTrace.exclusions[self.class][:rescue].include? :method
            raise e
          ensure
            `console.groupEnd()` rescue nil
          end
        end
      end
    end
  end
end
