/*
 * iasio.h — independent declaration of the ASIO host-side ABI.
 *
 * This file is NOT the Steinberg ASIO SDK and contains none of its code. It
 * describes the binary interface an ASIO driver exposes (a COM object whose
 * vtable extends IUnknown with the methods below, in this exact order), the
 * same way JUCE's juce_win32_ASIO.cpp and other SDK-free hosts do. The
 * driver is loaded with CoCreateInstance(clsid, NULL, CLSCTX_INPROC_SERVER,
 * clsid, ...) — the IID equals the CLSID, an ASIO quirk.
 *
 * On x64 Windows there is a single calling convention (the Microsoft x64
 * ABI), so MSVC's "thiscall" member functions are called exactly like a C
 * function whose first parameter is `this`. That is what makes a plain C
 * vtable struct work here; the x86 thunking that the SDK's asiodrvr.cpp
 * needs does not apply (we build x64 only).
 *
 * Licensing: "ASIO" is a trademark of Steinberg Media Technologies GmbH.
 * Shipping an ASIO host requires accepting Steinberg's ASIO SDK licence
 * agreement, even though the SDK sources are not needed to compile this
 * program. See LICENSES.md.
 *
 * Types: ASIO `long` is a 32-bit int (Windows LLP64), ASIOSampleRate is an
 * IEEE double (the SDK defines IEEE754_64FLOAT on Windows), ASIOSamples and
 * ASIOTimeStamp are {hi, lo} 32-bit pairs (NATIVE_INT64 is 0 on Windows).
 */
#ifndef OL1N_IASIO_H
#define OL1N_IASIO_H

#ifdef _WIN32
#include <windows.h>
#define ASIO_CALL __stdcall /* ignored on x64; kept for documentation */
#else
#define ASIO_CALL
typedef struct _GUID { unsigned long Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } GUID;
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef long ASIOBool;
enum { ASIOFalse = 0, ASIOTrue = 1 };

typedef long ASIOError;
enum {
    ASE_OK = 0,
    ASE_SUCCESS = 0x3f4847a0,     /* unique success value for ASIOFuture */
    ASE_NotPresent = -1000,       /* hardware input or output is not present or available */
    ASE_HWMalfunction,            /* hardware is malfunctioning */
    ASE_InvalidParameter,         /* input parameter invalid */
    ASE_InvalidMode,              /* hardware is in a bad mode or used in a bad mode */
    ASE_SPNotAdvancing,           /* hardware is not running when sample position is inquired */
    ASE_NoClock,                  /* sample clock or rate cannot be determined or is not present */
    ASE_NoMemory                  /* not enough memory for completing the request */
};

typedef double ASIOSampleRate;

typedef struct ASIOSamples   { unsigned long hi; unsigned long lo; } ASIOSamples;
typedef struct ASIOTimeStamp { unsigned long hi; unsigned long lo; } ASIOTimeStamp;

typedef long ASIOSampleType;
enum {
    ASIOSTInt16MSB   = 0,
    ASIOSTInt24MSB   = 1,   /* used for 20 bits as well */
    ASIOSTInt32MSB   = 2,
    ASIOSTFloat32MSB = 3,   /* IEEE 754 32 bit float */
    ASIOSTFloat64MSB = 4,   /* IEEE 754 64 bit double float */

    /* these are used for 32 bit data buffer, with different alignment of
     * the data inside; 32 bit PCI bus systems can be more easily used with
     * these */
    ASIOSTInt32MSB16 = 8,   /* 32 bit data with 16 bit alignment */
    ASIOSTInt32MSB18 = 9,   /* 32 bit data with 18 bit alignment */
    ASIOSTInt32MSB20 = 10,  /* 32 bit data with 20 bit alignment */
    ASIOSTInt32MSB24 = 11,  /* 32 bit data with 24 bit alignment */

    ASIOSTInt16LSB   = 16,
    ASIOSTInt24LSB   = 17,  /* used for 20 bits as well */
    ASIOSTInt32LSB   = 18,
    ASIOSTFloat32LSB = 19,  /* IEEE 754 32 bit float, as found on Intel x86 */
    ASIOSTFloat64LSB = 20,  /* IEEE 754 64 bit double float */

    ASIOSTInt32LSB16 = 24,  /* 32 bit data with 16 bit alignment (low 16 bits valid) */
    ASIOSTInt32LSB18 = 25,  /* 32 bit data with 18 bit alignment */
    ASIOSTInt32LSB20 = 26,  /* 32 bit data with 20 bit alignment */
    ASIOSTInt32LSB24 = 27,  /* 32 bit data with 24 bit alignment */

    /* ASIO DSD format */
    ASIOSTDSDInt8LSB1 = 32, /* DSD 1 bit data, 8 samples per byte. First sample in Least significant bit. */
    ASIOSTDSDInt8MSB1 = 33, /* DSD 1 bit data, 8 samples per byte. First sample in Most significant bit. */
    ASIOSTDSDInt8NER8 = 40, /* DSD 8 bit data, 1 sample per byte. No Endianness required. */

    ASIOSTLastEntry
};

typedef struct ASIOTimeCode {
    double        speed;            /* speed relation (fraction of nominal speed) */
    ASIOSamples   timeCodeSamples;  /* time code in samples */
    unsigned long flags;            /* kTcValid, kTcRunning, ... */
    char          future[64];
} ASIOTimeCode;

enum ASIOTimeCodeFlags {
    kTcValid       = 1,
    kTcRunning     = 1 << 1,
    kTcReverse     = 1 << 2,
    kTcOnspeed     = 1 << 3,
    kTcStill       = 1 << 4,
    kTcSpeedValid  = 1 << 8
};

typedef struct ASIOTimeInfo {
    double          speed;          /* absolute speed (1. = nominal) */
    ASIOTimeStamp   systemTime;     /* system time related to samplePosition, in nanoseconds */
    ASIOSamples     samplePosition;
    ASIOSampleRate  sampleRate;     /* current rate */
    unsigned long   flags;          /* see below */
    char            reserved[12];
} ASIOTimeInfo;

enum ASIOTimeInfoFlags {
    kSystemTimeValid     = 1,
    kSamplePositionValid = 1 << 1,
    kSampleRateValid     = 1 << 2,
    kSpeedValid          = 1 << 3,
    kSampleRateChanged   = 1 << 4,
    kClockSourceChanged  = 1 << 5
};

typedef struct ASIOTime {
    long         reserved[4];   /* must be 0 */
    ASIOTimeInfo timeInfo;      /* required */
    ASIOTimeCode timeCode;      /* optional, evaluated if (timeCode.flags & kTcValid) */
} ASIOTime;

typedef struct ASIOClockSource {
    long     index;             /* as used for setClockSource() */
    long     associatedChannel; /* first channel of clock source group */
    long     associatedGroup;   /* group of the channel */
    ASIOBool isCurrentSource;   /* ASIOTrue if it is the current clock source */
    char     name[32];
} ASIOClockSource;

typedef struct ASIOChannelInfo {
    long           channel;      /* on input, channel index */
    ASIOBool       isInput;      /* on input */
    ASIOBool       isActive;     /* on exit */
    long           channelGroup; /* dto */
    ASIOSampleType type;         /* dto */
    char           name[32];     /* dto */
} ASIOChannelInfo;

typedef struct ASIOBufferInfo {
    ASIOBool isInput;     /* on input: ASIOTrue: input, else output */
    long     channelNum;  /* on input: channel index */
    void    *buffers[2];  /* on output: double buffer addresses */
} ASIOBufferInfo;

typedef struct ASIOCallbacks {
    /* bufferSwitch indicates that both input and output are to be processed. */
    void (*bufferSwitch)(long doubleBufferIndex, ASIOBool directProcess);
    /* gets called when the AudioStreamIO detects a sample rate change */
    void (*sampleRateDidChange)(ASIOSampleRate sRate);
    /* generic callback for various purposes, see selectors below */
    long (*asioMessage)(long selector, long value, void *message, double *opt);
    /* new callback with time info. makes ASIOGetSamplePosition() and various
     * calls to ASIOGetSampleRate obsolete, and allows for timecode sync etc. */
    ASIOTime *(*bufferSwitchTimeInfo)(ASIOTime *params, long doubleBufferIndex, ASIOBool directProcess);
} ASIOCallbacks;

/* asioMessage selectors */
enum {
    kAsioSelectorSupported = 1,    /* selector in <value>, returns 1L if supported */
    kAsioEngineVersion,            /* returns engine (host) asio implementation version, 2 or higher */
    kAsioResetRequest,             /* request driver reset: stop, dispose, re-create, start */
    kAsioBufferSizeChange,         /* new buffer size in <value>; return 1 if accepted */
    kAsioResyncRequest,            /* driver went out of sync; host should resync */
    kAsioLatenciesChanged,         /* latencies changed, host should re-query */
    kAsioSupportsTimeInfo,         /* return 1 if the host supports bufferSwitchTimeInfo */
    kAsioSupportsTimeCode,         /* return 1 if the host supports time code */
    kAsioMMCCommand,               /* unused */
    kAsioSupportsInputMonitor,     /* return 1 if the host supports input monitoring */
    kAsioSupportsInputGain,
    kAsioSupportsInputMeter,
    kAsioSupportsOutputGain,
    kAsioSupportsOutputMeter,
    kAsioOverload,                 /* driver detected an overload */
    kAsioNumMessageSelectors
};

/* future selectors */
enum {
    kAsioEnableTimeCodeRead = 1,
    kAsioDisableTimeCodeRead,
    kAsioSetInputMonitor,
    kAsioTransport,
    kAsioSetInputGain,
    kAsioGetInputMeter,
    kAsioSetOutputGain,
    kAsioGetOutputMeter,
    kAsioCanInputMonitor,
    kAsioCanTimeInfo,
    kAsioCanTimeCode,
    kAsioCanTransport,
    kAsioCanInputGain,
    kAsioCanInputMeter,
    kAsioCanOutputGain,
    kAsioCanOutputMeter,
    kAsioOptionalOne,

    /* DSD support (ASIO 2.2) */
    kAsioSetIoFormat   = 0x23111961, /* sets the I/O format (ASIOIoFormat*) */
    kAsioGetIoFormat   = 0x23111983, /* gets the I/O format */
    kAsioCanDoIoFormat = 0x23112004, /* asks whether the format can be set */

    /* extensions (ASIO 2.3) */
    kAsioCanReportOverload        = 0x24042012, /* driver supports kAsioOverload */
    kAsioGetInternalBufferSamples = 0x25042012  /* ASIOInternalBufferInfo* */
};

/* kAsioCanDoInputMonitor is the name used by some headers for kAsioCanInputMonitor. */
#define kAsioCanDoInputMonitor kAsioCanInputMonitor

typedef long ASIOIoFormatType;
enum {
    kASIOFormatInvalid = -1,
    kASIOPCMFormat     = 0,
    kASIODSDFormat     = 1
};

typedef struct ASIOIoFormat_s {
    ASIOIoFormatType FormatType;
    char             future[512 - sizeof(ASIOIoFormatType)];
} ASIOIoFormat;

typedef struct ASIOInternalBufferInfo {
    long inputSamples;  /* size of driver's internal input buffering, in samples */
    long outputSamples; /* dto for output */
} ASIOInternalBufferInfo;

/* ---- the driver object ------------------------------------------------- */

typedef struct IASIO IASIO;

typedef struct IASIOVtbl {
    /* IUnknown */
    long (ASIO_CALL *QueryInterface)(IASIO *self, const GUID *riid, void **ppv);
    unsigned long (ASIO_CALL *AddRef)(IASIO *self);
    unsigned long (ASIO_CALL *Release)(IASIO *self);
    /* IASIO, in declaration order */
    ASIOBool  (ASIO_CALL *init)(IASIO *self, void *sysHandle);
    void      (ASIO_CALL *getDriverName)(IASIO *self, char *name);      /* at least 32 bytes */
    long      (ASIO_CALL *getDriverVersion)(IASIO *self);
    void      (ASIO_CALL *getErrorMessage)(IASIO *self, char *string);  /* at least 124 bytes */
    ASIOError (ASIO_CALL *start)(IASIO *self);
    ASIOError (ASIO_CALL *stop)(IASIO *self);
    ASIOError (ASIO_CALL *getChannels)(IASIO *self, long *numInputChannels, long *numOutputChannels);
    ASIOError (ASIO_CALL *getLatencies)(IASIO *self, long *inputLatency, long *outputLatency);
    ASIOError (ASIO_CALL *getBufferSize)(IASIO *self, long *minSize, long *maxSize, long *preferredSize, long *granularity);
    ASIOError (ASIO_CALL *canSampleRate)(IASIO *self, ASIOSampleRate sampleRate);
    ASIOError (ASIO_CALL *getSampleRate)(IASIO *self, ASIOSampleRate *sampleRate);
    ASIOError (ASIO_CALL *setSampleRate)(IASIO *self, ASIOSampleRate sampleRate);
    ASIOError (ASIO_CALL *getClockSources)(IASIO *self, ASIOClockSource *clocks, long *numSources);
    ASIOError (ASIO_CALL *setClockSource)(IASIO *self, long reference);
    ASIOError (ASIO_CALL *getSamplePosition)(IASIO *self, ASIOSamples *sPos, ASIOTimeStamp *tStamp);
    ASIOError (ASIO_CALL *getChannelInfo)(IASIO *self, ASIOChannelInfo *info);
    ASIOError (ASIO_CALL *createBuffers)(IASIO *self, ASIOBufferInfo *bufferInfos, long numChannels, long bufferSize, ASIOCallbacks *callbacks);
    ASIOError (ASIO_CALL *disposeBuffers)(IASIO *self);
    ASIOError (ASIO_CALL *controlPanel)(IASIO *self);
    ASIOError (ASIO_CALL *future)(IASIO *self, long selector, void *opt);
    ASIOError (ASIO_CALL *outputReady)(IASIO *self);
} IASIOVtbl;

struct IASIO {
    const IASIOVtbl *lpVtbl;
};

#ifdef __cplusplus
}
#endif
#endif /* OL1N_IASIO_H */
