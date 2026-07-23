#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t mihomo_start_with_config(const char *configPath, const char *workingDirectory);
int32_t mihomo_reload_config(const char *configPath);
int32_t mihomo_stop(void);
int32_t mihomo_is_running(void);

#ifdef __cplusplus
}
#endif
