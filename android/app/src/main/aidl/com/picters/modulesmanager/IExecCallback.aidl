package com.picters.modulesmanager;

/**
 * Async reply channel for {@link IKernelService#exec}. Declared `oneway` so the
 * root service delivers results back to the app without ever blocking on the
 * caller — replies are fire-and-forget and correlated by requestId.
 */
oneway interface IExecCallback {
    /** The script finished: merged stdout+stderr in [output], shell [exitCode]. */
    void onComplete(int requestId, int exitCode, String output);

    /** The script could not complete (timeout, exception, shell died). */
    void onError(int requestId, String message);
}
