#ifndef ColumbaPython_Bridging_Header_h
#define ColumbaPython_Bridging_Header_h

#import <Python/Python.h>

// Swift cannot express `PyConfig_SetString(&config, &config.home, ...)` because of
// overlapping-access exclusivity rules — both arguments alias into `config`.
// These tiny inline shims pull the dual-mutation pattern down into C, which
// has no such restriction. One shim per `PyConfig` field we touch.

static inline PyStatus ColumbaPy_PyConfig_SetHome(PyConfig *config, const wchar_t *home) {
    return PyConfig_SetString(config, &config->home, home);
}

// Py_None is a macro in CPython's headers, which Swift cannot import. This
// shim returns a fresh reference so the caller can pass it where a "new"
// reference is expected (e.g. PyTuple_SetItem, which steals refs).
static inline PyObject *ColumbaPy_None(void) {
    Py_INCREF(Py_None);
    return Py_None;
}

#endif
