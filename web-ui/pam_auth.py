"""Small PAM authentication adapter using the host's existing PAM stack."""

import ctypes
import ctypes.util
import threading

PAM_SUCCESS = 0
PAM_BUF_ERR = 5
PAM_CONV_ERR = 19
PAM_PROMPT_ECHO_OFF = 1
PAM_PROMPT_ECHO_ON = 2
PAM_RHOST = 4
# Linux-PAM never sends more than PAM_MAX_NUM_MSG (32) messages at once.
PAM_MAX_NUM_MSG = 32


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    # A raw address: PAM takes ownership of the strdup()ed buffer and frees it.
    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conversation", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


_libraries = None
_libraries_lock = threading.Lock()


def _load_libraries():
    """Load libpam and libc once; find_library() spawns ldconfig on every call."""
    global _libraries
    with _libraries_lock:
        if _libraries is None:
            pam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
            libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
            pam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                      ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
            pam.pam_start.restype = ctypes.c_int
            pam.pam_set_item.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
            pam.pam_set_item.restype = ctypes.c_int
            pam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
            pam.pam_authenticate.restype = ctypes.c_int
            pam.pam_acct_mgmt.argtypes = [ctypes.c_void_p, ctypes.c_int]
            pam.pam_acct_mgmt.restype = ctypes.c_int
            pam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
            pam.pam_end.restype = ctypes.c_int
            libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
            libc.calloc.restype = ctypes.c_void_p
            libc.strdup.argtypes = [ctypes.c_char_p]
            libc.strdup.restype = ctypes.c_void_p
            libc.free.argtypes = [ctypes.c_void_p]
            libc.free.restype = None
            _libraries = (pam, libc)
        return _libraries


def authenticate(username, password, service="login", rhost=None):
    """Authenticate once through an existing PAM service.

    The password is passed only through the in-memory conversation callback.
    No PAM configuration or account/session state is changed here. ``rhost``
    is reported to PAM (PAM_RHOST) so faillock/access policies and logs see
    the client address.
    """
    if "\x00" in username or "\x00" in password:
        return False  # strdup() would silently truncate at the NUL byte
    pam, libc = _load_libraries()
    username_bytes = username.encode("utf-8")
    password_bytes = password.encode("utf-8")

    @CONV_FUNC
    def conversation(num_msg, message_ptr, response_ptr, _appdata):
        # An exception escaping a ctypes callback yields an undefined return
        # value, which PAM could read as PAM_SUCCESS: fail closed instead.
        response_memory = None
        duplicates = []
        try:
            if not 0 < num_msg <= PAM_MAX_NUM_MSG or not message_ptr or not response_ptr:
                return PAM_CONV_ERR
            response_memory = libc.calloc(num_msg, ctypes.sizeof(PamResponse))
            if not response_memory:
                return PAM_BUF_ERR
            responses = ctypes.cast(response_memory, ctypes.POINTER(PamResponse))
            for index in range(num_msg):
                message = message_ptr[index].contents
                if message.msg_style not in (PAM_PROMPT_ECHO_ON, PAM_PROMPT_ECHO_OFF):
                    continue  # informational text needs no answer (calloc zeroed it)
                value = username_bytes if message.msg_style == PAM_PROMPT_ECHO_ON else password_bytes
                duplicate = libc.strdup(value)
                if not duplicate:
                    raise MemoryError
                duplicates.append(duplicate)
                responses[index].resp = duplicate
            response_ptr[0] = responses
            return PAM_SUCCESS  # PAM now owns and frees the response array
        except Exception as error:
            for duplicate in duplicates:
                libc.free(duplicate)
            if response_memory:
                libc.free(response_memory)
            return PAM_BUF_ERR if isinstance(error, MemoryError) else PAM_CONV_ERR

    handle = ctypes.c_void_p()
    conversation_struct = PamConv(conversation, None)
    result = pam.pam_start(service.encode("ascii"), username_bytes,
                           ctypes.byref(conversation_struct), ctypes.byref(handle))
    if result != PAM_SUCCESS:
        return False
    try:
        if rhost:
            result = pam.pam_set_item(handle, PAM_RHOST, str(rhost).encode("ascii", "replace"))
        if result == PAM_SUCCESS:
            result = pam.pam_authenticate(handle, 0)
        if result == PAM_SUCCESS:
            result = pam.pam_acct_mgmt(handle, 0)
        return result == PAM_SUCCESS
    finally:
        pam.pam_end(handle, result)
