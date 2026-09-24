#ifndef ColumbaNEPython_Bridging_Header_h
#define ColumbaNEPython_Bridging_Header_h

// NE-specific Python bridging header.
//
// The NE target does NOT import RNSAPI / ReticulumSwift through the same
// bridging path as the app: the NE is Python-only (its sole Reticulum runtime
// is the in-NE Python RNS node), so a NE file is either a Python file or an
// ordinary Swift file - never a ReticulumSwift file. This header exposes ONLY
// the CPython C API so the NE's embedded-Python runtime (NEPythonRuntime) can
// call Py_* directly without dragging in RNSAPI's re-declared RNS types.
//
// The app's Sources/PythonBridge/ColumbaPython-Bridging-Header.h carries the
// same inline shims (PyConfig_SetString aliasing workaround, Py_None/True/
// False macro accessors) because Swift cannot express them directly.

#import <Python/Python.h>

static inline PyStatus ColumbaNEPy_PyConfig_SetHome(PyConfig *config, const wchar_t *home) {
    return PyConfig_SetString(config, &config->home, home);
}

static inline PyObject *ColumbaNEPy_None(void) {
    Py_INCREF(Py_None);
    return Py_None;
}

#endif
