
class CMockGeneratorUtils

  attr_accessor :config, :helpers, :ordered, :ptr_handling, :arrays, :cexception

  def initialize(config, helpers={})
    @config = config
    @ptr_handling = @config.when_ptr
    @ordered = @config.enforce_strict_ordering
    @arrays = @config.plugins.include? :array
    @cexception = @config.plugins.include? :cexception
    @treat_as = @config.treat_as
	  @helpers = helpers
    
    if (@arrays)
      case(@ptr_handling)
        when :smart        then alias :code_verify_an_arg_expectation :code_verify_an_arg_expectation_with_smart_arrays 
        when :compare_data then alias :code_verify_an_arg_expectation :code_verify_an_arg_expectation_with_normal_arrays 
        when :compare_ptr  then raise "ERROR: the array plugin doesn't enjoy working with :compare_ptr only.  Disable one option."
      end
    else
      alias :code_verify_an_arg_expectation :code_verify_an_arg_expectation_with_no_arrays
    end
  end
  
  def code_add_base_expectation(func_name, global_ordering_supported=true)
    lines =  "  CMOCK_#{func_name}_CALL_INSTANCE* cmock_call_instance = (CMOCK_#{func_name}_CALL_INSTANCE*)CMock_Guts_MemNew(sizeof(CMOCK_#{func_name}_CALL_INSTANCE));\n"
    lines << "  UNITY_TEST_ASSERT_NOT_NULL(cmock_call_instance, cmock_line, \"CMock has run out of memory. Please allocate more.\");\n"
    lines << "  Mock.#{func_name}_CallInstance = (CMOCK_#{func_name}_CALL_INSTANCE*)CMock_Guts_MemChain((void*)Mock.#{func_name}_CallInstance, (void*)cmock_call_instance);\n"
    lines << "  cmock_call_instance->LineNumber = cmock_line;\n"
    lines << "  cmock_call_instance->CallOrder = ++GlobalExpectCount;\n" if (@ordered and global_ordering_supported)
    lines << "  cmock_call_instance->ExceptionToThrow = CEXCEPTION_NONE;\n" if (@cexception)
    lines
  end
  
  def code_add_an_arg_expectation(arg, depth=1) 
    lines =  code_assign_argument_quickly("cmock_call_instance->Expected_#{arg[:name]}", arg)
    lines << "  cmock_call_instance->Expected_#{arg[:name]}_Depth = #{arg[:name]}_Depth;\n" if (@arrays and (depth.class == String))
    lines
  end
  
  def code_assign_argument_quickly(dest, arg) 
    if (arg[:ptr?] or @treat_as.include?(arg[:type]))
      "  #{dest} = #{arg[:const?] ? "(#{arg[:type]})" : ''}#{arg[:name]};\n"
    else
      "  memcpy(&#{dest}, &#{arg[:name]}, sizeof(#{arg[:type]}));\n"
    end
  end
  
  def code_add_argument_loader(function)
    if (function[:args_string] != "void")
      if (@arrays)
        args_string = function[:args].map do |m| 
          const_str = m[ :const? ] ? 'const ' : ''
          m[:ptr?] ? "#{const_str}#{m[:type]} #{m[:name]}, int #{m[:name]}_Depth" : "#{const_str}#{m[:type]} #{m[:name]}"
        end.join(', ')
        "void CMockExpectParameters_#{function[:name]}(CMOCK_#{function[:name]}_CALL_INSTANCE* cmock_call_instance, #{args_string})\n{\n" + 
        function[:args].inject("") { |all, arg| all + code_add_an_arg_expectation(arg, (arg[:ptr?] ? "#{arg[:name]}_Depth" : 1) ) } +
        "}\n\n"
      else
        "void CMockExpectParameters_#{function[:name]}(CMOCK_#{function[:name]}_CALL_INSTANCE* cmock_call_instance, #{function[:args_string]})\n{\n" + 
        function[:args].inject("") { |all, arg| all + code_add_an_arg_expectation(arg) } +
        "}\n\n"
      end
    else
      ""
    end
  end
  
  def code_call_argument_loader(function)
    if (function[:args_string] != "void")
      args = function[:args].map do |m|
        (@arrays and m[:ptr?]) ? "#{m[:name]}, 1" : m[:name]
      end
      "  CMockExpectParameters_#{function[:name]}(cmock_call_instance, #{args.join(', ')});\n" 
    else
      ""
    end
  end
  
  #private ######################
  
  def lookup_expect_type(function, arg)
    c_type     = arg[:type]
    arg_name   = arg[:name]
    expected   = "cmock_call_instance->Expected_#{arg_name}" 
    unity_func = if ((arg[:ptr?]) and (@ptr_handling == :compare_ptr))
                   "UNITY_TEST_ASSERT_EQUAL_HEX32"
                 else
                   (@helpers.nil? or @helpers[:unity_helper].nil?) ? "UNITY_TEST_ASSERT_EQUAL" : @helpers[:unity_helper].get_helper(c_type)
                 end
    unity_msg  = ", \"Function '#{function[:name]}' called with unexpected value for argument '#{arg_name}'.\""
    return c_type, arg_name, expected, unity_func, unity_msg
  end
  
  def code_verify_an_arg_expectation_with_no_arrays(function, arg)
    c_type, arg_name, expected, unity_func, unity_msg = lookup_expect_type(function, arg)
    case(unity_func)
      when "UNITY_TEST_ASSERT_EQUAL_MEMORY"
        full_expected = (expected =~ /^\*/) ? expected.slice(1..-1) : "(&#{expected})"
        return "  UNITY_TEST_ASSERT_EQUAL_MEMORY((void*)#{full_expected}, (void*)(&#{arg_name}), sizeof(#{c_type}), cmock_line#{unity_msg});\n"
      when "UNITY_TEST_ASSERT_EQUAL_MEMORY"
        [ "  if (#{expected} == NULL)",
          "    { UNITY_TEST_ASSERT_NULL(#{arg_name}, cmock_line, NULL); }",
          "  else",
          "    { UNITY_TEST_ASSERT_EQUAL_MEMORY((void*)(#{expected}), (void*)#{arg_name}, sizeof(#{c_type.sub('*','')}), cmock_line#{unity_msg}); }\n"].join("\n")
      when /_ARRAY/
        [ "  if (#{expected} == NULL)",
          "    { UNITY_TEST_ASSERT_NULL(#{arg_name}, cmock_line, NULL); }",
          "  else",
          "    { #{unity_func}(#{expected}, #{arg_name}, 1, cmock_line, NULL); }\n"].join("\n")
      else
        return "  #{unity_func}(#{expected}, #{arg_name}, cmock_line#{unity_msg});\n" 
    end  
  end
  
  def code_verify_an_arg_expectation_with_normal_arrays(function, arg)
    c_type, arg_name, expected, unity_func, unity_msg = lookup_expect_type(function, arg)
    depth_name = (arg[:ptr?]) ? "cmock_call_instance->Expected_#{arg_name}_Depth" : 1
    case(unity_func)
      when "UNITY_TEST_ASSERT_EQUAL_MEMORY"
        full_expected = (expected =~ /^\*/) ? expected.slice(1..-1) : "(&#{expected})"
        return "  UNITY_TEST_ASSERT_EQUAL_MEMORY((void*)#{full_expected}, (void*)(&#{arg_name}), sizeof(#{c_type}), cmock_line#{unity_msg});\n"
      when "UNITY_TEST_ASSERT_EQUAL_MEMORY_ARRAY"
        [ "  if (#{expected} == NULL)",
          "    { UNITY_TEST_ASSERT_NULL(#{arg_name}, cmock_line, NULL); }",
          "  else",
          "    { UNITY_TEST_ASSERT_EQUAL_MEMORY_ARRAY((void*)(#{expected}), (void*)#{arg_name}, sizeof(#{c_type.sub('*','')}), #{depth_name}, cmock_line#{unity_msg}); }\n"].compact.join("\n")
      when /_ARRAY/
        [ "  if (#{expected} == NULL)",
          "    { UNITY_TEST_ASSERT_NULL(#{arg_name}, cmock_line, NULL); }",
          "  else",
          "    { #{unity_func}(#{expected}, #{arg_name}, #{depth_name}, cmock_line, NULL); }\n"].compact.join("\n")
      else
        return "  #{unity_func}(#{expected}, #{arg_name}, cmock_line#{unity_msg});\n" 
    end
  end
  
  def code_verify_an_arg_expectation_with_smart_arrays(function, arg)
    c_type, arg_name, expected, unity_func, unity_msg = lookup_expect_type(function, arg)
    depth_name = (arg[:ptr?]) ? "cmock_call_instance->Expected_#{arg_name}_Depth" : 1
    case(unity_func)
      when "UNITY_TEST_ASSERT_EQUAL_MEMORY"
        full_expected = (expected =~ /^\*/) ? expected.slice(1..-1) : "(&#{expected})"
        return "  UNITY_TEST_ASSERT_EQUAL_MEMORY((void*)#{full_expected}, (void*)(&#{arg_name}), sizeof(#{c_type}), cmock_line#{unity_msg});\n"
      when "UNITY_TEST_ASSERT_EQUAL_MEMORY_ARRAY"
        [ "  if (#{expected} == NULL)",
          "    { UNITY_TEST_ASSERT_NULL(#{arg_name}, cmock_line, NULL); }",
          ((depth_name != 1) ? "  else if (#{depth_name} == 0)\n    { UNITY_TEST_ASSERT_EQUAL_HEX32(#{expected}, #{arg_name}, cmock_line, NULL); }" : nil),
          "  else",
          "    { UNITY_TEST_ASSERT_EQUAL_MEMORY_ARRAY((void*)(#{expected}), (void*)#{arg_name}, sizeof(#{c_type.sub('*','')}), #{depth_name}, cmock_line#{unity_msg}); }\n"].compact.join("\n")
      when /_ARRAY/
        [ "  if (#{expected} == NULL)",
          "    { UNITY_TEST_ASSERT_NULL(#{arg_name}, cmock_line, NULL); }",
          ((depth_name != 1) ? "  else if (#{depth_name} == 0)\n    { UNITY_TEST_ASSERT_EQUAL_HEX32(#{expected}, #{arg_name}, cmock_line, NULL); }" : nil),
          "  else",
          "    { #{unity_func}(#{expected}, #{arg_name}, #{depth_name}, cmock_line, NULL); }\n"].compact.join("\n")
      else
        return "  #{unity_func}(#{expected}, #{arg_name}, cmock_line#{unity_msg});\n" 
    end
  end
  
end