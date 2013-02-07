# Things assigned to root will be available outside this module.
root = exports ? window.runtime ?= {}

_ = require '../vendor/_.js'
gLong = require '../vendor/gLong.js'
util = require './util'
types = require './types'
ClassFile = require './ClassFile'
{log,vtrace,trace,debug,error} = require './logging'
{java_throw,YieldIOException,ReturnException,JavaException} = require './exceptions'
{JavaObject,JavaClassObject,JavaArray,thread_name} = require './java_object'
{c2t} = types
{Method} = require './methods'

"use strict"

class root.CallStack
  constructor: (initial_stack) ->
    @_cs = [root.StackFrame.fake_frame('$bootstrap')]
    if initial_stack?
      @_cs[0].stack = initial_stack

  length: -> @_cs.length
  push: (sf) -> @_cs.push sf
  pop: -> @_cs.pop()

  curr_frame: -> util.last(@_cs)

  get_caller: (frames_to_skip) -> @_cs[@_cs.length-1-frames_to_skip]

class root.StackFrame
  constructor: (@method,@locals,@stack) ->
    @pc = 0
    @runner = null
    @name = @method.full_signature()

  @fake_frame: (name) ->
    sf = new root.StackFrame(new Method(null, c2t(name)), [], [])
    sf.name = name
    sf.fake = true
    return sf

  # Creates a "native stack frame". Handler is called with no arguments for
  # normal execution, error_handler is called with the uncaught exception.
  # If error_handler is not specified, then the exception will propagate through
  # normally.
  # Used for <clinit> and ClassLoader shenanigans. A native frame handles
  # bridging the gap between those Java methods and the methods that ended up
  # triggering them in the first place.
  @native_frame: (name, handler, error_handler) ->
    sf = new root.StackFrame(new Method(null, c2t(name)), [], [])
    sf.runner = handler
    sf.name = name
    if error_handler? then sf.error = error_handler
    sf.native = true
    return sf

# Contains all the mutable state of the Java program.
class root.RuntimeState

  run_count = 0

  constructor: (@print, @async_input, @read_classfile) ->
    @startup_time = gLong.fromNumber (new Date).getTime()
    @run_stamp = ++run_count
    # dict of ClassFiles that have been loaded. this is two levels deep:
    # the first level is the classloader, the second level is the classes
    # defined by that classloader.
    @loaded_classes = Object.create null

    @mem_start_addrs = [1]
    @mem_blocks = {}

    @high_oref = 1
    @string_pool = new util.SafeMap
    @lock_refs = {}  # map from monitor -> thread object
    @lock_counts = {}  # map from monitor -> count
    @waiting_threads = {}  # map from monitor -> list of waiting thread objects
    @thread_pool = []
    @curr_thread = {$meta_stack: new root.CallStack()}

  # XXX: We currently 'preinitialize' all of these to avoid an async call
  # in the middle of JVM execution. We should attempt to prune this down as
  # much as possible.
  preinitialize_core_classes: (resume_cb, except_cb) ->
    core_classes = [
      'sun/misc/VM'
      'java/lang/String'
      'java/lang/NoSuchFieldError'
      'java/lang/ArrayIndexOutOfBoundsException'
      'java/lang/ClassCastException'
      'java/lang/Thread'
      'java/lang/Throwable'
      'java/lang/NullPointerException'
      'java/lang/reflect/Field'
      'java/lang/Error'
      'java/lang/reflect/Method'
      'java/lang/reflect/Constructor'
      'java/lang/Class'
      'java/lang/StackTraceElement'
      'java/nio/ByteOrder'
      'java/lang/ArrayStoreException'
      'java/io/IOException'
      'java/lang/IllegalMonitorStateException'
      'java/lang/ArrayIndexOutOfBoundsException'
      'java/lang/System'
      'java/lang/InterruptedException'
      'java/io/ExpiringCache'
      'java/io/UnixFileSystem'
      'java/io/FileNotFoundException'
      'java/io/FileDescriptor'
      'java/lang/ThreadGroup'
      'java/lang/NullPointerException'
      'java/lang/NegativeArraySizeException'
      'java/lang/NoSuchMethodError'
      'java/lang/Cloneable'
      'java/io/Serializable'
      'java/lang/ArithmeticException'
      'sun/reflect/ConstantPool'
      'java/lang/ExceptionInInitializerError'
    ]
    i = -1
    init_next_core_class = =>
      trace "init_next_core_class"
      i++
      if i < core_classes.length
        trace "Initializing #{core_classes[i]}"
        @initialize_class c2t(core_classes[i]), null, init_next_core_class, except_cb
      else
        trace "Preinitialization complete."
        resume_cb()

    init_next_core_class()

  init_threads: ->
    # initialize thread objects
    my_sf = @curr_frame()
    @push (group = @init_object @class_lookup(c2t 'java/lang/ThreadGroup'))
    @method_lookup(@class_lookup(c2t 'java/lang/ThreadGroup'), {class: 'java/lang/ThreadGroup', sig: '<init>()V'}).setup_stack(this)
    my_sf.runner = =>
      ct = null
      my_sf.runner = =>
        my_sf.runner = null
        ct.$meta_stack = @meta_stack()
        @curr_thread = ct
        @curr_thread.$isAlive = true
        @thread_pool.push @curr_thread
        # hack to make auto-named threads match native Java
        @class_lookup(c2t 'java/lang/Thread').static_fields.threadInitNumber = 1
        debug "### finished thread init ###"
      ct = @init_object @class_lookup(c2t 'java/lang/Thread'),
        'java/lang/Thread/name': @init_carr 'main'
        'java/lang/Thread/priority': 1
        'java/lang/Thread/group': group
        'java/lang/Thread/threadLocals': null

  meta_stack: -> @curr_thread.$meta_stack

  # Init the first class, and put the command-line args on the stack for use by
  # its main method.

  init_system_class: ->
    # initialize the system class
    my_sf = @curr_frame()
    @class_lookup(c2t 'java/lang/System').methods['initializeSystemClass()V'].setup_stack(this)
    my_sf.runner = ->
      my_sf.runner = null
      @system_initialized = true
      debug "### finished system class initialization ###"

  init_args: (initial_args) ->
    args = new JavaArray @, @class_lookup(c2t('[Ljava/lang/String;')), (@init_string(a) for a in initial_args)
    @curr_thread.$meta_stack = new root.CallStack [args]
    debug "### finished runtime state initialization ###"

  show_state: () ->
    cf = @curr_frame()
    if cf?
      s = ((if x?.ref? then x.ref else x) for x in cf.stack)
      l = ((if x?.ref? then x.ref else x) for x in cf.locals)
      debug "showing current state: method '#{cf.method?.name}', stack: [#{s}], locals: [#{l}]"
    else
      debug "current frame is undefined. meta_stack: #{@meta_stack()}"

  choose_next_thread: (blacklist) ->
    unless blacklist?
      blacklist = []
      for key,bl of @waiting_threads
        for b in bl
          blacklist.push b
    for t in @thread_pool when t isnt @curr_thread and t.$isAlive
      continue if t in blacklist
      debug "TE(choose_next_thread): choosing thread #{thread_name(@, t)}"
      return t
    # we couldn't find a thread! We can't error out, so keep trying
    debug "TE(choose_next_thread): no thread found, sticking with curr_thread"
    return @curr_thread

  wait: (monitor, yieldee) ->
    # add current thread to wait queue
    debug "TE(wait): waiting #{thread_name @, @curr_thread} on lock #{monitor.ref}"
    if @waiting_threads[monitor]?
      @waiting_threads[monitor].push @curr_thread
    else
      @waiting_threads[monitor] = [@curr_thread]
    # yield execution to a non-waiting thread
    yieldee ?= @choose_next_thread @waiting_threads[monitor]
    @yield yieldee

  yield: (yieldee=@choose_next_thread()) ->
    debug "TE(yield): yielding #{thread_name @, @curr_thread} to #{thread_name @, yieldee}"
    old_thread_sf = @curr_frame()
    @curr_thread = yieldee
    new_thread_sf = @curr_frame()
    new_thread_sf.runner = => @meta_stack().pop()
    old_thread_sf.runner = => @meta_stack().pop()
    throw ReturnException

  curr_frame: -> @meta_stack().curr_frame()

  cl: (idx) -> @curr_frame().locals[idx]
  put_cl: (idx,val) -> @curr_frame().locals[idx] = val
  # Category 2 values (longs, doubles) take two slots in Java. Since we only
  # need one slot to represent a double in JS, we pad it with a null.
  put_cl2: (idx,val) -> @put_cl(idx,val); UNSAFE? || @put_cl(idx+1,null)

  push: (arg) -> @curr_frame().stack.push(arg)
  push2: (arg1, arg2) -> @curr_frame().stack.push(arg1, arg2)
  push_array: (args) ->
    cs = @curr_frame().stack
    Array::push.apply(cs, args)
  pop: () -> @curr_frame().stack.pop()
  pop2: () -> @pop(); @pop() # For category 2 values.

  # Program counter manipulation.
  curr_pc: ()   -> @curr_frame().pc
  goto_pc: (pc) -> @curr_frame().pc = pc
  inc_pc:  (n)  -> @curr_frame().pc += n

  # Heap manipulation.
  check_null: (obj) ->
    java_throw @, @class_lookup(c2t 'java/lang/NullPointerException'), '' unless obj?
    obj

  heap_newarray: (type,len) ->
    if len < 0
      java_throw @, @class_lookup(c2t 'java/lang/NegativeArraySizeException'), "Tried to init [#{type} array with length #{len}"
    if type == 'J'
      new JavaArray @, @class_lookup(c2t("[J")), (gLong.ZERO for i in [0...len] by 1)
    else if type[0] == 'L'  # array of object
      new JavaArray @, @class_lookup(c2t("[#{type}")), (null for i in [0...len] by 1)
    else  # numeric array
      new JavaArray @, @class_lookup(c2t("[#{type}")), (0 for i in [0...len] by 1)

  # heap object initialization
  init_object: (cls, obj) ->
    new JavaObject @, cls, obj
  init_array: (cls, obj) ->
    new JavaArray @, cls, obj
  init_string: (str,intern=false) ->
    trace "init_string: #{str}"
    return s if intern and (s = @string_pool.get str)?
    carr = @init_carr str
    type = c2t('java/lang/String')
    jvm_str = new JavaObject @, @class_lookup(type), {'java/lang/String/value':carr, 'java/lang/String/count':str.length}
    @string_pool.set(str, jvm_str) if intern
    return jvm_str
  init_carr: (str) ->
    new JavaArray @, @class_lookup(c2t('[C')), (str.charCodeAt(i) for i in [0...str.length] by 1)

  # Loads the underlying class, its parents, and its interfaces, but does not
  # run class initialization.
  # trigger_class is a ClassFile object for the class that triggered this load
  # request.
  # Calls success_fn with the loaded class when finished.
  # Calls failure_fn with a function that throws an exception in the event of a
  # failure.
  load_class: (type, trigger_class, success_fn, failure_fn) ->
    cls = type.toClassString()
    trace "Loading #{cls}..."
    loader = if trigger_class? then trigger_class.get_class_loader() else null
    loader_id = if trigger_class? then trigger_class.get_class_loader_id() else null

    # First time this ClassLoader has loaded a class.
    unless @loaded_classes[loader_id]? then @loaded_classes[loader_id] = Object.create null

    cls_obj = @get_loaded_class(type, null, true)
    if cls_obj?
      @loaded_classes[loader_id][cls] = cls_obj
      success_fn cls_obj
      return

    if @loaded_classes[loader_id][cls]?
      setTimeout((()=>success_fn(@loaded_classes[loader_id][cls])), 0)
    else
      if type instanceof types.ArrayType
        @loaded_classes[loader_id][cls] = ClassFile.for_array_type type, loader
        if type.component_type instanceof types.PrimitiveType
          success_fn @loaded_classes[loader_id][cls]
          return
        else
          @load_class type.component_type, trigger_class, (() =>
            success_fn @loaded_classes[loader_id][cls]
          ), failure_fn
          return
      else
        # a class gets loaded with the loader of the class that is triggering
        # this class resolution
        if loader?
          root.StackFrame.native_frame("$#{loader_id}", (()=>
            @meta_stack().pop()
            success_fn @loaded_classes[loader_id][cls]
          ), ((e)=>
            @meta_stack().pop()
            # XXX: Convert the exception.
            setTimeout((()->failure_fn(()->throw e)), 0)
          ))
          @push2 loader, @init_string util.ext_classname cls
          # We don't care about the return value of this function, as
          # define_class handles registering the ClassFile with the class loader.
          # define_class also handles recalling load_class for any needed super
          # classes and interfaces.
          loader.method_lookup(@, {sig: 'loadClass(Ljava/lang/String;)Ljava/lang/Class;'}).setup_stack(@)
          return
        else
          # bootstrap class loader
          @read_classfile cls, ((class_file) =>
            if not class_file? or wrong_name = (class_file.toClassString() != cls)
              msg = cls
              if wrong_name
                msg += " (wrong name: #{class_file.toClassString()})"
              # XXX: Fix this... exception is different depending if the class
              # was dynamically loaded.
              #if dyn
              #  failure_fn ()=>java_throw @, @class_lookup(c2t 'java/lang/ClassNotFoundException'), msg
              #else
              failure_fn ()=>java_throw @, @class_lookup(c2t 'java/lang/NoClassDefFoundError'), msg
              return
            # Tell the ClassFile that we are loading it. It will reset any
            # internal state in case we are re-loading.
            class_file.load()
            @loaded_classes[loader_id][cls] = class_file

            # Load any interfaces of this class before returning.
            i = -1 # Will increment to 0 first iteration.
            num_interfaces = class_file.interfaces.length
            load_next_iface = () =>
              i++
              if i < num_interfaces
                iface_type = c2t(class_file.constant_pool.get(class_file.interfaces[i]).deref())
                @load_class iface_type, trigger_class, load_next_iface, failure_fn
              else
                setTimeout((()->success_fn class_file), 0)

            # Now that this class is loaded, let's grab the super classes and
            # interfaces.
            if class_file.super_class?
              @load_class class_file.super_class, trigger_class, load_next_iface, failure_fn
            else
              load_next_iface()
          )

  # XXX: This is a bit of a hack.
  # There are some classes we can load synchronously (array types for
  # initialized classes, primitive classes, etc). Try to do so here.
  _try_synchronous_load: (type, trigger_class=null) ->
    loader = if trigger_class? then trigger_class.loader else null
    loader_id = if trigger_class? then trigger_class.get_class_loader_id() else null
    @loaded_classes[loader_id] = Object.create null unless @loaded_classes[loader_id]?
    if type instanceof types.PrimitiveType
      @loaded_classes[loader_id][type.toExternalString()] = ClassFile.for_primitive type, loader
      return @loaded_classes[loader_id][type.toExternalString()]
    else if type instanceof types.ArrayType
      # Ensure the component type is loaded. We do *not* load classes unless all
      # of its superclasses/components/interfaces are loaded.
      comp_cls = @get_loaded_class type.component_type, trigger_class, true
      return null unless comp_cls?
      @loaded_classes[loader_id][type.toClassString()] = ClassFile.for_array_type type, loader
      return @loaded_classes[loader_id][type.toClassString()]
    return null


  # Synchronous method for looking up a class that is *already loaded and
  # initialized*.
  # trigger_class is a ClassFile that specifies what class triggered the
  # lookup attempt. A value of 'null' means the JVM.
  # If null_handled is set, this returns null if the class is not loaded or not
  # initialized.
  # Otherwise, this function throws an exception to indicate the error.
  # TODO: Once things stabilize, disable the exception throwing in UNSAFE mode.
  class_lookup: (type, trigger_class=null, null_handled=false) ->
    UNSAFE? || throw new Error "class_lookup needs a type object, got #{typeof type}: #{type}" unless type instanceof types.Type
    loader_id = if trigger_class? then trigger_class.get_class_loader_id() else null
    cls = @loaded_classes[loader_id]?[type.toClassString()]
    # We use cls.is_initialized() rather than checking cls.initialized directly.
    # This allows us to avoid asynchronously "initializing" classes that have no
    # clinit and whose parents are already initialized.
    return cls if cls?.is_initialized(@)

    # XXX: Hack for primitive arrays. Should fix.
    unless cls?
      cls = @_try_synchronous_load type, trigger_class
      return cls if cls?.is_initialized(@)

    # Class needs to be loaded and/or initialized.
    return null if null_handled

    reason = if cls? then 'initialized' else 'loaded'
    msg = "class_lookup failed: Class #{type.toClassString()} is not #{reason}."
    throw new Error msg

  # Like class_lookup, but it only ensures that the class is loaded.
  # XXX: Should probably use a better naming convention or combine this with
  # class_lookup somehow.
  get_loaded_class: (type, trigger_class=null, null_handled=false) ->
    UNSAFE? || throw new Error "get_loaded_class needs a type object, got #{typeof type}: #{type}" unless type instanceof types.Type
    loader_id = if trigger_class? then trigger_class.get_class_loader_id() else null
    cls = @loaded_classes[loader_id]?[type.toClassString()]
    # We use cls.is_initialized() rather than checking cls.initialized directly.
    # This allows us to avoid asynchronously "initializing" classes that have no
    # clinit and whose parents are already initialized.
    return cls if cls?

    # XXX: Hack for primitive arrays. Plz fix.
    cls = @_try_synchronous_load type, trigger_class
    return cls if cls?

    # Class needs to be loaded.
    return null if null_handled

    msg = "get_loaded_class failed: Class #{type.toClassString()} is not loaded."
    throw new Error msg

  # Runs clinit on the indicated class. Should only be called _immediately_
  # before a method invocation or field access. See section 5.5 of the SE7
  # spec. Loads in the class if necessary.
  # "trigger_class" should be the ClassFile object of the class that
  # triggered this initialization. This is needed for custom class loader
  # support.
  # This should be called as an rs.async_op either from an opcode, or a
  # native function. **You should not be calling this from anywhere else.**
  initialize_class: (type, trigger_class, success_fn, failure_fn) ->
    name = type.toClassString()
    loader = if trigger_class? then trigger_class.get_class_loader_id() else null
    class_file = @loaded_classes[loader]?[name]

    # Don't use failure_fn for this error -- the main RS loop will handle it.
    throw new Error "ERROR: Tried to initialize #{name} while in the main RuntimeState loop. Should be called as an async op." if @_in_main_loop

    # Class file is not loaded. Load it and come back later.
    unless class_file?
      # This monstrosity uses setTimeout to reset the JS stack, calls load_class,
      # and tells load_class to reset the JS stack w/ setTimeout and call it
      # back when it succeeds. If it does not succeed, then it'll just call the
      # failure function.
      # XXX: If loading fails during initialization, do we have to modify the
      # exception thrown?
      trace "initialize_class: Loading class #{name}."
      setTimeout((() =>
        @load_class(type, trigger_class, (()=>
          setTimeout((()=>@initialize_class type, trigger_class, success_fn, failure_fn), 0)
        ), failure_fn)
      ), 0)
      return
    # Class file is loaded and initialized; insert a NOP function.
    # XXX: This should never happen, but it currently will if multiple Java
    # threads happen to try to initialize the same class at the 'same' time. And
    # if THAT happens, then the second thread will be using an uninitialized
    # class... Revisit when we refactor our Threads support. Some ideas:
    # A) "Lock in" a thread during <clinit> to prevent it from being preempted.
    #    This is not ideal. Don't do this.
    # B) Add a bit to the ClassFile object that specifies if it is in the
    #    process of being initialized. If it is set, put the thread in a queue
    #    for resumption when the ClassFile is eventually initialized. The thread
    #    responsible for running <clinit> will check the queue after setting the
    #    'initialized' flag, and will push all of the waiting threads onto the
    #    whatever we currently use as a "ready queue".
    else if class_file.initialized
      trace "initialize_class called on a class that was already initialized: #{class_file.toClassString()}"
      setTimeout((()->success_fn(class_file)), 0)
      return

    # Iterate through the class hierarchy, pushing StackFrames that run
    # <clinit> functions onto the stack. The last StackFrame pushed will be for
    # the <clinit> function of the topmost uninitialized class in the hierarchy.
    first_clinit = true
    first_native_frame = root.StackFrame.native_frame("$clinit", (()=>
      throw new Error "The top of the meta stack should be this native frame, but it is not: #{@curr_frame().name} at #{@meta_stack().length()}" if @curr_frame() != first_native_frame
      @meta_stack().pop()
      # success_fn is responsible for getting us back into the runtime state
      # execution loop.
      @async_op(()=>success_fn(@loaded_classes[loader][name]))
    ), ((e)=>
      if e instanceof JavaException
        # We hijack the current native frame to transform the exception into a
        # ExceptionInInitializerError, then call failure_fn to throw it.
        # failure_fn is responsible for getting us back into the runtime state
        # loop.
        # We don't use the java_throw helper since this Exception object takes
        # a Throwable as an argument.
        nf = @curr_frame()
        nf.runner = =>
          rv = @pop()
          @meta_stack().pop()
          # Throw the exception.
          throw (new JavaException(rv))
        nf.error = => @meta_stack().pop(); failure_fn(()->throw e)

        cls = @class_lookup c2t('java/lang/ExceptionInInitializerError')
        v = @init_object cls # new
        method_spec = sig: '<init>(Ljava/lang/Throwable;)V'
        @push_array([v,v,e.exception]) # dup, ldc
        @method_lookup(cls, method_spec).setup_stack(@) # invokespecial
      else
        # Not a Java exception?
        # No idea what this is; let's get outta dodge and rethrow it.
        @meta_stack().pop()
        throw e
    ))
    while class_file? and not class_file.is_initialized(@)
      trace "initializing class: #{class_file.toClassString()}"
      class_file.initialized = true

      # Resets any cached state from previous JVM executions (browser).
      class_file.initialize()

      # Run class initialization code. Superclasses get init'ed first.  We
      # don't want to call this more than once per class, so don't do dynamic
      # lookup. See spec [2.17.4][1].
      # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/Concepts.doc.html#19075
      # XXX: Hack. We don't use method_lookup since we want only the method in *this* class.
      clinit = class_file.methods['<clinit>()V']
      if clinit?
        trace "\tFound <clinit>. Pushing stack frame."
        # Push a native frame; needed to handle exceptions and the callback.
        if first_clinit
          trace "\tFirst <clinit> in the loop."
          first_clinit = false
          # The first frame calls success_fn on success. Subsequent frames
          # are only used to handle exceptions.
          @meta_stack().push(first_native_frame)
        else
          @meta_stack().push root.StackFrame.native_frame("$clinit_secondary", (()=>
            @meta_stack().pop()
          ), ((e)=>
            until @curr_frame() is first_native_frame
              @meta_stack.pop()
            @meta_stack.pop() # Pop that first native frame.
            # Rethrow the exception. failure_fn is responsible for getting us back
            # into the runtime state loop.
            @async_op(()=>failure_fn(()->throw e))
          ))
        clinit.setup_stack(@)
      next_type = if class_file.super_class? then class_file.super_class else if class_file.component_type? then class_file.component_type else undefined
      class_file = if next_type? then @loaded_classes[loader][next_type.toClassString()] else undefined

    unless first_clinit
      # Push ourselves back into the execution loop to run the <clinit> methods.
      @run_until_finished((->), false, (->))
      return

    # Classes did not have any clinit functions, and were already loaded.
    setTimeout((()=>success_fn(@loaded_classes[loader][name])), 0)

  # called by user-defined classloaders
  # must be called as an asynchronous operation.
  define_class: (cls, data, loader, success_fn, failure_fn) ->
    # replicates some logic from load_class
    class_file = new ClassFile data, loader
    type = c2t(cls)

    # XXX: The details of get_loader_id in ClassFile are leaking out here.
    loader_id = if loader? then loader.ref else null
    @loaded_classes[loader_id] = Object.create null unless @loaded_classes[loader_id]?
    @loaded_classes[loader_id][cls] = class_file

    # XXX: Copypasta'd from load_class.
    # Load any interfaces of this class before returning.
    i = -1 # Will increment to 0 first iteration.
    num_interfaces = class_file.interfaces.length
    load_next_iface = () =>
      i++
      if i < num_interfaces
        iface_type = c2t(class_file.constant_pool.get(class_file.interfaces[i]).deref())
        # XXX: We're passing in 'loader' rather than a trigger_class. This needs to be fixed
        # for proper ClassLoader support.
        @load_class iface_type, loader, load_next_iface, failure_fn
      else
        setTimeout((()=>success_fn @loaded_classes[loader_id][cls].get_class_object(@)), 0)

    if class_file.super_class?
      @load_class class_file.super_class, class_file, load_next_iface, failure_fn
    else
      load_next_iface()

  method_lookup: (cls, method_spec) ->
    method = cls.method_lookup(this, method_spec)
    return method if method?
    java_throw @, @class_lookup(c2t 'java/lang/NoSuchMethodError'),
      "No such method found in #{method_spec.class}: #{method_spec.sig}"

  field_lookup: (cls, field_spec) ->
    field = cls.field_lookup this, field_spec
    return field if field?
    java_throw @, @class_lookup(c2t 'java/lang/NoSuchFieldError'),
      "No such field found in #{field_spec.class}: #{field_spec.name}"

  # address of the block that this address is contained in
  block_addr: (address) ->
    address = address.toNumber() # address is a Long
    if DataView?
      block_addr = @mem_start_addrs[0]
      for addr in @mem_start_addrs[1..]
        if address < addr
          return block_addr
        block_addr = addr
    else
      # w/o typed arrays, we just address by 32bits.
      # We initialize memory to 0, so it should not be 0 or undefined.
      if @mem_blocks[address]?
        return address
    UNSAFE? || throw new Error "Invalid memory access at #{address}"

  handle_toplevel_exception: (e, no_threads, done_cb) ->
    if e.toplevel_catch_handler?
      @run_until_finished (=> e.toplevel_catch_handler(@)), no_threads, done_cb
    else
      error "\nInternal JVM Error:", e
      error e.stack if e?.stack?
      @show_state()
      done_cb false
    return

  # Pauses the JVM for an asynchronous operation. The callback, cb, will be
  # called with another callback that it is responsible for calling with any
  # return values when it is time to resume the JVM.
  async_op: (cb) -> throw new YieldIOException cb

  run_until_finished: (setup_fn, no_threads, done_cb) ->
    @_in_main_loop = true
    try
      setup_fn()
      while true
        sf = @curr_frame()
        while sf.runner?
          sf.runner()
          sf = @curr_frame()
        # we've finished this thread, no more runners
        # we're done if the only thread is "main"
        break if no_threads or @thread_pool.length <= 1
        # remove the current (finished) thread
        debug "TE(toplevel): finished thread #{thread_name @, @curr_thread}"
        @curr_thread.$isAlive = false
        @thread_pool.splice @thread_pool.indexOf(@curr_thread), 1
        @curr_thread = @choose_next_thread()
      done_cb true
    catch e
      @_in_main_loop = false
      if e == 'Error in class initialization'
        done_cb false
      else if e is ReturnException
        # XXX: technically we shouldn't get here. Right now we get here
        # when java_throw is called from the main method lookup.
        @run_until_finished (->), no_threads, done_cb
      else if e instanceof YieldIOException
        # Set "bytecode" if this was triggered by a bytecode instruction (e.g.
        # class initialization). This causes the method to resume on the next
        # opcode once success_fn is called.
        success_fn = (ret1, ret2, bytecode, advance_pc=true) =>
          if bytecode then @meta_stack().push root.StackFrame.fake_frame("async_op")
          @curr_frame().runner = =>
              @meta_stack().pop()
              if bytecode and advance_pc
                @curr_frame().pc += 1 + @curr_frame().method.code.opcodes[@curr_frame().pc].byte_count
              unless ret1 is undefined
                trace "Success_fn pushin' some stuff onto stack"
                ret1 += 0 if typeof ret1 == 'boolean'
                @push ret1
              @push ret2 unless ret2 is undefined
          @run_until_finished (->), no_threads, done_cb
        failure_fn = (e_cb, bytecode) =>
          if bytecode then @meta_stack().push root.StackFrame.fake_frame("async_op")
          @curr_frame().runner = ()=> @meta_stack().pop(); e_cb()
          @run_until_finished (->), no_threads, done_cb
        e.condition success_fn, failure_fn
      else
        if e.method_catch_handler? and @meta_stack().length() > 1
          tos = true
          until e.method_catch_handler(@, @curr_frame().method, tos)
            tos = false
            if @meta_stack().length() == 1
              @handle_toplevel_exception e, no_threads, done_cb
              return
            else
              @meta_stack().pop()
          @run_until_finished (->), no_threads, done_cb
        else
          @meta_stack().pop() while @meta_stack().length() > 1
          @handle_toplevel_exception e, no_threads, done_cb
    return  # this is an async method, no return value
