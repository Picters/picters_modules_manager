package com.picters.modulesmanager;

/**
 * Replies are correlated by requestId. Chunk callbacks are synchronous so
 * Binder acknowledges each bounded parcel before the service sends another.
 */
interface IExecCallback {
    /** A bounded part of stdout; ordered before onComplete. */
    void onOutputChunk(int requestId, String output);
    /** The script finished: merged stdout+stderr in [output], shell [exitCode]. */
    void onComplete(int requestId, int exitCode, String output);

    /** The script could not complete (timeout, exception, shell died). */
    void onError(int requestId, String message);
}
