#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t mihomo_start_with_config(const char *configPath, const char *workingDirectory);
int32_t mihomo_reload_config(const char *configPath);
int32_t mihomo_stop(void);
int32_t mihomo_is_running(void);

/// Returns malloc'ed UTF-8 error string from the last failed bridge call.
/// Caller must free() the returned pointer. Returns NULL when no error.
char *mihomo_get_last_error(void);

#ifdef __cplusplus
}
#endif
