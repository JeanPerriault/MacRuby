/*
 * MacRuby ObjC helpers.
 *
 * This file is covered by the Ruby license. See COPYING for more details.
 * 
 * Copyright (C) 2007-2010, Apple Inc. All rights reserved.
 */

#include <Foundation/Foundation.h>
#include "ruby/ruby.h"
#include "ruby/node.h"
#include "ruby/encoding.h"
#include "ruby/objc.h"
#include "vm.h"
#include "objc.h"
#include "id.h"

#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#if HAVE_BRIDGESUPPORT_FRAMEWORK
# include <BridgeSupport/BridgeSupport.h>
#else
# include "bs.h"
#endif

static inline const char *
rb_get_bs_method_type(bs_element_method_t *bs_method, int arg)
{
    if (bs_method != NULL) {
	if (arg == -1) {
	    if (bs_method->retval != NULL) {
		return bs_method->retval->type;
	    }
	}
	else {
	    int i;
	    for (i = 0; i < bs_method->args_count; i++) {
		if (bs_method->args[i].index == arg) {
		    return bs_method->args[i].type;
		}
	    }
	}
    }
    return NULL;
}

bool
rb_objc_get_types(VALUE recv, Class klass, SEL sel, Method method,
		  bs_element_method_t *bs_method, char *buf, size_t buflen)
{
    const char *type;
    unsigned i;

    if (method != NULL) {
	if (bs_method == NULL) {
	    type = method_getTypeEncoding(method);
	    assert(strlen(type) < buflen);
	    buf[0] = '\0';
	    do {
		const char *type2 = SkipFirstType(type);
		strncat(buf, type, type2 - type);
		type = SkipStackSize(type2);
	    }
	    while (*type != '\0');
	    //strlcpy(buf, method_getTypeEncoding(method), buflen);
	    //sig->argc = method_getNumberOfArguments(method);
	}
	else {
	    char buf2[100];
	    type = rb_get_bs_method_type(bs_method, -1);
	    if (type != NULL) {
		strlcpy(buf, type, buflen);
	    }
	    else {
		method_getReturnType(method, buf2, sizeof buf2);
		strlcpy(buf, buf2, buflen);
	    }

	    //sig->argc = method_getNumberOfArguments(method);
	    int argc = method_getNumberOfArguments(method);
	    for (i = 0; i < argc; i++) {
		if (i >= 2 && (type = rb_get_bs_method_type(bs_method, i - 2))
			!= NULL) {
		    strlcat(buf, type, buflen);
		}
		else {
		    method_getArgumentType(method, i, buf2, sizeof(buf2));
		    strlcat(buf, buf2, buflen);
		}
	    }
	}
	return true;
    }
    else if (!SPECIAL_CONST_P(recv)) {
	NSMethodSignature *msig = [(id)recv methodSignatureForSelector:sel];
	if (msig != NULL) {
	    unsigned i;

	    type = rb_get_bs_method_type(bs_method, -1);
	    if (type == NULL) {
		type = [msig methodReturnType];
	    }
	    strlcpy(buf, type, buflen);

	    //sig->argc = [msig numberOfArguments];
	    int argc = [msig numberOfArguments];
	    for (i = 0; i < argc; i++) {
		if (i < 2 || (type = rb_get_bs_method_type(bs_method, i - 2))
			== NULL) {
		    type = [msig getArgumentTypeAtIndex:i];
		}
		strlcat(buf, type, buflen);
	    }

	    return true;
	}
    }
    return false;
}

static id _symbolicator = nil;
#define SYMBOLICATION_FRAMEWORK @"/System/Library/PrivateFrameworks/Symbolication.framework"

typedef struct _VMURange {
    uint64_t location;
    uint64_t length;
} VMURange;

@interface NSObject (SymbolicatorAPIs) 
- (id)symbolicatorForTask:(mach_port_t)task;
- (id)symbolForAddress:(uint64_t)address;
- (void)forceFullSymbolExtraction;
- (VMURange)addressRange;
@end

static inline id
rb_objc_symbolicator(void) 
{
    if (_symbolicator == nil) {
	NSError *error;

	if (![[NSBundle bundleWithPath:SYMBOLICATION_FRAMEWORK]
		loadAndReturnError:&error]) {
	    NSLog(@"Cannot load Symbolication.framework: %@", error);
	    abort();    
	}

	Class VMUSymbolicator = NSClassFromString(@"VMUSymbolicator");
	_symbolicator = [VMUSymbolicator symbolicatorForTask:mach_task_self()];
	assert(_symbolicator != nil);
    }

    return _symbolicator;
}

bool
rb_objc_symbolize_address(void *addr, void **start, char *name,
			  size_t name_len) 
{
    Dl_info info;
    if (dladdr(addr, &info) != 0) {
	if (info.dli_saddr != NULL) {
	    if (start != NULL) {
		*start = info.dli_saddr;
	    }
	    if (name != NULL) {
		strncpy(name, info.dli_sname, name_len);
	    }
	    return true;
	}
    }

#if 1
    return false;
#else
    id symbolicator = rb_objc_symbolicator();
    id symbol = [symbolicator symbolForAddress:(NSUInteger)addr];
    if (symbol == nil) {
	return false;
    }
    VMURange range = [symbol addressRange];
    if (start != NULL) {
	*start = (void *)(NSUInteger)range.location;
    }
    if (name != NULL) {
	strncpy(name, [[symbol name] UTF8String], name_len);
    }
    return true;
#endif
}

VALUE
rb_file_expand_path(VALUE fname, VALUE dname)
{
    NSString *res = (NSString *)FilePathValue(fname);

    if ([res isAbsolutePath]) {
      NSString *tmp = [res stringByResolvingSymlinksInPath];
      // Make sure we don't have an invalid user path.
      if ([res hasPrefix:@"~"] && [tmp isEqualTo:res]) {
        NSString *user = [[[res pathComponents] objectAtIndex:0] substringFromIndex:1];
        rb_raise(rb_eArgError, "user %s doesn't exist", [user UTF8String]);
      }
      res = tmp;
    }
    else {
      NSString *dir = dname != Qnil ?
        (NSString *)FilePathValue(dname) : [[NSFileManager defaultManager] currentDirectoryPath];

      if (![dir isAbsolutePath]) {
        dir = (NSString *)rb_file_expand_path((VALUE)dir, Qnil);
      }

      // stringByStandardizingPath does not expand "/." to "/".
      if ([res isEqualTo:@"."] && [dir isEqualTo:@"/"]) {
        res = @"/";
      }
      else {
        res = [[dir stringByAppendingPathComponent:res] stringByStandardizingPath];
      }
    }

    return (VALUE)[res mutableCopy];
}

static VALUE
rb_objc_load_bs(VALUE recv, SEL sel, VALUE path)
{
    rb_vm_load_bridge_support(StringValuePtr(path), NULL, 0);
    return recv;
}

static void
rb_objc_search_and_load_bridge_support(const char *framework_path)
{
    char path[PATH_MAX];

    if (bs_find_path(framework_path, path, sizeof path)) {
	rb_vm_load_bridge_support(path, framework_path,
                                    BS_PARSE_OPTIONS_LOAD_DYLIBS);
    }
}

static void
reload_class_constants(void)
{
    static int class_count = 0;
    int i, count;
    Class *buf;

    count = objc_getClassList(NULL, 0);
    if (count == class_count) {
	return;
    }

    buf = (Class *)alloca(sizeof(Class) * count);
    objc_getClassList(buf, count);

    for (i = 0; i < count; i++) {
	Class k = buf[i];
	if (!RCLASS_RUBY(k)) {
	    const char *name = class_getName(k);
	    if (name[0] != '_') {
		ID name_id = rb_intern(name);
		if (!rb_const_defined(rb_cObject, name_id)) {
		    rb_const_set(rb_cObject, name_id, (VALUE)k);
		}
	    }
	}
    }

    class_count = count;
}

static void
reload_protocols(void)
{
#if 0
    Protocol **prots;
    unsigned int i, prots_count;

    prots = objc_copyProtocolList(&prots_count);
    for (i = 0; i < prots_count; i++) {
	Protocol *p;
	struct objc_method_description *methods;
	unsigned j, methods_count;

	p = prots[i];

#define REGISTER_MDESCS(t) // TODO

	methods = protocol_copyMethodDescriptionList(p, true, true,
		&methods_count);
	REGISTER_MDESCS(bs_inf_prot_imethods);
	methods = protocol_copyMethodDescriptionList(p, false, true,
		&methods_count);
	REGISTER_MDESCS(bs_inf_prot_imethods);
	methods = protocol_copyMethodDescriptionList(p, true, false,
		&methods_count);
	REGISTER_MDESCS(bs_inf_prot_cmethods);
	methods = protocol_copyMethodDescriptionList(p, false, false,
		&methods_count);
	REGISTER_MDESCS(bs_inf_prot_cmethods);

#undef REGISTER_MDESCS
    }
    free(prots);
#endif
}

VALUE
rb_require_framework(VALUE recv, SEL sel, int argc, VALUE *argv)
{
    VALUE framework;
    VALUE search_network;
    const char *cstr;
    NSFileManager *fileManager;
    NSString *path;
    NSBundle *bundle;
    NSError *error;
    
    rb_scan_args(argc, argv, "11", &framework, &search_network);

    Check_Type(framework, T_STRING);
    cstr = RSTRING_PTR(framework);

    fileManager = [NSFileManager defaultManager];
    path = [fileManager stringWithFileSystemRepresentation:cstr
	length:strlen(cstr)];

    if (![fileManager fileExistsAtPath:path]) {
	/* framework name is given */
	NSSearchPathDomainMask pathDomainMask;
	NSString *frameworkName;
	NSArray *dirs;
	NSUInteger i, count;

	cstr = NULL;

#define FIND_LOAD_PATH_IN_LIBRARY(dir) 					  \
    do { 								  \
	path = [[dir stringByAppendingPathComponent:@"Frameworks"]	  \
	   stringByAppendingPathComponent:frameworkName];		  \
	if ([fileManager fileExistsAtPath:path])  			  \
	    goto success; 						  \
	path = [[dir stringByAppendingPathComponent:@"PrivateFrameworks"] \
	   stringByAppendingPathComponent:frameworkName];		  \
	if ([fileManager fileExistsAtPath:path]) 			  \
	    goto success; 						  \
    } 									  \
    while(0)

	pathDomainMask = RTEST(search_network)
	    ? NSAllDomainsMask
	    : NSUserDomainMask | NSLocalDomainMask | NSSystemDomainMask;

	frameworkName = [path stringByAppendingPathExtension:@"framework"];

	path = [[[[NSBundle mainBundle] bundlePath] 
	    stringByAppendingPathComponent:@"Contents/Frameworks"] 
		stringByAppendingPathComponent:frameworkName];
	if ([fileManager fileExistsAtPath:path]) {
	    goto success;
	}

	dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, 
	    pathDomainMask, YES);
	for (i = 0, count = [dirs count]; i < count; i++) {
	    NSString *dir = [dirs objectAtIndex:i];
	    FIND_LOAD_PATH_IN_LIBRARY(dir);
	}	

	dirs = NSSearchPathForDirectoriesInDomains(NSDeveloperDirectory, 
	    pathDomainMask, YES);
	for (i = 0, count = [dirs count]; i < count; i++) {
	    NSString *dir = [[dirs objectAtIndex:i] 
		stringByAppendingPathComponent:@"Library"];
	    FIND_LOAD_PATH_IN_LIBRARY(dir); 
	}
	
    dirs = [[[[NSProcessInfo processInfo] environment] valueForKey:@"DYLD_FRAMEWORK_PATH"] componentsSeparatedByString: @":"];
    for (i = 0, count = [dirs count]; i < count; i++) {
        NSString *dir = [dirs objectAtIndex:i];
        path = [dir stringByAppendingPathComponent:frameworkName];
        if ([fileManager fileExistsAtPath:path])
            goto success;
    }

#undef FIND_LOAD_PATH_IN_LIBRARY

	rb_raise(rb_eRuntimeError, "framework `%s' not found", 
		RSTRING_PTR(framework));
    }

success:

    if (cstr == NULL) {
	cstr = [path fileSystemRepresentation];
    }

    bundle = [NSBundle bundleWithPath:path];
    if (bundle == nil) {
	rb_raise(rb_eRuntimeError, 
	         "framework at path `%s' cannot be located",
		 cstr);
    }

    if ([bundle isLoaded]) {
	return Qfalse;
    }

    if (![bundle loadAndReturnError:&error]) {
	rb_raise(rb_eRuntimeError,
		 "framework at path `%s' cannot be loaded: %s",
		 cstr,
		 [[error description] UTF8String]); 
    }

    rb_objc_search_and_load_bridge_support(cstr);
    reload_class_constants();
    reload_protocols();

    return Qtrue;
}

void rb_vm_init_compiler(void);

static void
rb_objc_kvo_setter_imp(void *recv, SEL sel, void *value)
{
    const char *selname;
    char buf[128];
    size_t s;   

    selname = sel_getName(sel);
    buf[0] = '@';
    buf[1] = tolower(selname[3]);
    s = strlcpy(&buf[2], &selname[4], sizeof buf - 2);
    buf[s + 1] = '\0';

    rb_ivar_set((VALUE)recv, rb_intern(buf), value == NULL
	    ? Qnil : OC2RB(value));
}

/*
  Defines an attribute writer method which conforms to Key-Value Coding.
  (See http://developer.apple.com/documentation/Cocoa/Conceptual/KeyValueCoding/KeyValueCoding.html)
  
    attr_accessor :foo
  
  Will create the normal accessor methods, plus <tt>setFoo</tt>
  
  TODO: Does not handle the case were the user might override #foo=
*/
void
rb_objc_define_kvo_setter(VALUE klass, ID mid)
{
    char buf[100];
    const char *mid_name;

    buf[0] = 's'; buf[1] = 'e'; buf[2] = 't';
    mid_name = rb_id2name(mid);

    buf[3] = toupper(mid_name[0]);
    buf[4] = '\0';
    strlcat(buf, &mid_name[1], sizeof buf);
    strlcat(buf, ":", sizeof buf);

    if (!class_addMethod((Class)klass, sel_registerName(buf), 
			 (IMP)rb_objc_kvo_setter_imp, "v@:@")) {
	rb_warning("can't register `%s' as an KVO setter on class `%s' "\
		"(method `%s')",
		mid_name, rb_class2name(klass), buf);
    }
}

VALUE
rb_mod_objc_ib_outlet(VALUE recv, SEL sel, int argc, VALUE *argv)
{
    int i;

    rb_warn("ib_outlet has been deprecated, please use attr_writer instead");

    for (i = 0; i < argc; i++) {
	VALUE sym = argv[i];
	
	Check_Type(sym, T_SYMBOL);
	rb_objc_define_kvo_setter(recv, SYM2ID(sym));
    }

    return recv;
}

static void *__obj_flags; // used as a static key

long
rb_objc_flag_get_mask(const void *obj)
{
    return (long)rb_objc_get_associative_ref((void *)obj, &__obj_flags);
}

bool
rb_objc_flag_check(const void *obj, int flag)
{
    const long v = rb_objc_flag_get_mask(obj);
    if (v == 0) {
	return false; 
    }
    return (v & flag) == flag;
}

void
rb_objc_flag_set(const void *obj, int flag, bool val)
{
    long v = (long)rb_objc_get_associative_ref((void *)obj, &__obj_flags);
    if (val) {
	v |= flag;
    }
    else {
	v ^= flag;
    }
    rb_objc_set_associative_ref((void *)obj, &__obj_flags, (void *)v);
}

static IMP old_imp_isaForAutonotifying;

static Class
rb_obj_imp_isaForAutonotifying(void *rcv, SEL sel)
{
    long ret_version;

    Class ret = ((Class (*)(void *, SEL))old_imp_isaForAutonotifying)(rcv, sel);

    if (ret != NULL && ((ret_version = RCLASS_VERSION(ret)) & RCLASS_KVO_CHECK_DONE) == 0) {
	const char *name = class_getName(ret);
	if (strncmp(name, "NSKVONotifying_", 15) == 0) {
	    Class ret_orig;
	    name += 15;
	    ret_orig = objc_getClass(name);
	    if (ret_orig != NULL) {
		const long orig_v = RCLASS_VERSION(ret_orig);
		if ((orig_v & RCLASS_IS_OBJECT_SUBCLASS) == RCLASS_IS_OBJECT_SUBCLASS) {
		    ret_version |= RCLASS_IS_OBJECT_SUBCLASS;
		}
		if ((orig_v & RCLASS_IS_RUBY_CLASS) == RCLASS_IS_RUBY_CLASS) {
		    ret_version |= RCLASS_IS_RUBY_CLASS;
		}
	    }
	}
	ret_version |= RCLASS_KVO_CHECK_DONE;
	RCLASS_SET_VERSION(ret, ret_version);
    }
    return ret;
}

id
rb_rb2oc_exception(VALUE exc)
{
    NSString *name = [NSString stringWithUTF8String:rb_obj_classname(exc)];
    NSString *reason = [(id)exc performSelector:@selector(message)];
#if 0
    // This is technically not required, and it seems that some exceptions
    // don't like to be treated like NSDictionary values...
    NSDictionary *dict = [NSDictionary dictionaryWithObject:(id)exc
	forKey:@"RubyException"];
#else
    NSDictionary *dict = nil;
#endif
    return [NSException exceptionWithName:name reason:reason userInfo:dict];
}

VALUE
rb_oc2rb_exception(id exc)
{
    char buf[1000];
    snprintf(buf, sizeof buf, "%s: %s", [[exc name] UTF8String],
	    [[exc reason] UTF8String]);
    return rb_exc_new2(rb_eRuntimeError, buf);
}

size_t
rb_objc_type_size(const char *type)
{
    @try {
	NSUInteger size, align;
	NSGetSizeAndAlignment(type, &size, &align);
	return size;
    }
    @catch (id ex) {
	rb_raise(rb_eRuntimeError, "can't get the size of type `%s': %s",
		type, [[ex description] UTF8String]);
    }
    return 0; // never reached
}

void *placeholder_String = NULL;
void *placeholder_Dictionary = NULL;
void *placeholder_Array = NULL;

void
Init_ObjC(void)
{
    rb_objc_define_method(rb_mKernel, "load_bridge_support_file",
	    rb_objc_load_bs, 1);

    Method m = class_getInstanceMethod(objc_getClass("NSKeyValueUnnestedProperty"), sel_registerName("isaForAutonotifying"));
    assert(m != NULL);
    old_imp_isaForAutonotifying = method_getImplementation(m);
    method_setImplementation(m, (IMP)rb_obj_imp_isaForAutonotifying);

    placeholder_String = objc_getClass("NSPlaceholderMutableString");
    placeholder_Dictionary = objc_getClass("__NSPlaceholderDictionary");
    placeholder_Array = objc_getClass("__NSPlaceholderArray");
}

@interface Protocol
@end

@implementation Protocol (MRFindProtocol)
+(id)protocolWithName:(NSString *)name
{
    return (id)objc_getProtocol([name UTF8String]);
} 
@end
