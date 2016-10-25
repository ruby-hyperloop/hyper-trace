if RUBY_ENGINE=='opal'
  require 'hyper_trace/hyper_trace.rb'
  require 'hyper_trace/react_trace.rb'
else
  Opal.append_path File.expand_path('../', __FILE__).untaint
end
