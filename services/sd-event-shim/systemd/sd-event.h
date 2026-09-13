/*
 * sd-event.h - the subset of systemd's sd-event that Mira needs.
 *
 * flutter-pi requires libsystemd, but in Buildroot the systemd package can only
 * be built when systemd is also init - and Mira is a BusyBox-init appliance that
 * boots in two seconds. flutter-pi turns out to use sd-event in 103 places and
 * sd-bus in none, so rather than adopt systemd or carry a large patch against
 * flutter-pi, Mira provides the event loop itself.
 *
 * This is API-compatible with sd-event for the functions declared here, and
 * deliberately nothing more. It is not systemd and does not aim to be.
 */

#ifndef MIRA_SD_EVENT_H
#define MIRA_SD_EVENT_H

#include <inttypes.h>
#include <signal.h>
#include <sys/types.h>
#include <time.h>

/* systemd's sd-event.h pulls these in, and callers rely on it: flutter-pi uses
 * EPOLLIN/EPOLLHUP/EPOLLPRI/EPOLLRDHUP having been declared by this header
 * alone. Dropping these includes breaks its build with no obvious cause. */
#include <sys/epoll.h>
#include <sys/signalfd.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sd_event sd_event;
typedef struct sd_event_source sd_event_source;

/* Enabled states. A ONESHOT source disables itself once it has fired. */
enum {
	SD_EVENT_OFF = 0,
	SD_EVENT_ON = 1,
	SD_EVENT_ONESHOT = -1
};

/* Loop states, driven by prepare/wait/dispatch. */
enum {
	SD_EVENT_INITIAL,
	SD_EVENT_ARMED,
	SD_EVENT_PENDING,
	SD_EVENT_RUNNING,
	SD_EVENT_EXITING,
	SD_EVENT_FINISHED,
	SD_EVENT_PREPARING
};

/* Lower value dispatches first. */
#define SD_EVENT_PRIORITY_IMPORTANT (-100)
#define SD_EVENT_PRIORITY_NORMAL    (0)
#define SD_EVENT_PRIORITY_IDLE      (100)

typedef int (*sd_event_handler_t)(sd_event_source *s, void *userdata);
typedef int (*sd_event_io_handler_t)(sd_event_source *s, int fd, uint32_t revents, void *userdata);
typedef int (*sd_event_time_handler_t)(sd_event_source *s, uint64_t usec, void *userdata);

int sd_event_new(sd_event **ret);
sd_event *sd_event_ref(sd_event *e);
sd_event *sd_event_unref(sd_event *e);

int sd_event_add_io(sd_event *e, sd_event_source **ret, int fd, uint32_t events,
		    sd_event_io_handler_t callback, void *userdata);
int sd_event_add_time(sd_event *e, sd_event_source **ret, clockid_t clock,
		      uint64_t usec, uint64_t accuracy,
		      sd_event_time_handler_t callback, void *userdata);
int sd_event_add_defer(sd_event *e, sd_event_source **ret,
		       sd_event_handler_t callback, void *userdata);

int sd_event_prepare(sd_event *e);
int sd_event_wait(sd_event *e, uint64_t timeout_usec);
int sd_event_dispatch(sd_event *e);
int sd_event_run(sd_event *e, uint64_t timeout_usec);
int sd_event_loop(sd_event *e);
int sd_event_exit(sd_event *e, int code);

int sd_event_get_fd(sd_event *e);
int sd_event_get_state(sd_event *e);
int sd_event_get_exit_code(sd_event *e, int *ret);

sd_event_source *sd_event_source_ref(sd_event_source *s);
sd_event_source *sd_event_source_unref(sd_event_source *s);
sd_event_source *sd_event_source_disable_unref(sd_event_source *s);

int sd_event_source_set_enabled(sd_event_source *s, int enabled);
int sd_event_source_get_enabled(sd_event_source *s, int *ret);
int sd_event_source_set_priority(sd_event_source *s, int64_t priority);
int sd_event_source_set_floating(sd_event_source *s, int b);
int sd_event_source_set_time(sd_event_source *s, uint64_t usec);
int sd_event_source_set_userdata(sd_event_source *s, void *userdata);
void *sd_event_source_get_userdata(sd_event_source *s);
int sd_event_source_get_pending(sd_event_source *s);

/* Used with __attribute__((cleanup(...))), exactly as systemd's headers are. */
static inline void sd_event_unrefp(sd_event **e)
{
	if (e && *e)
		*e = sd_event_unref(*e);
}

static inline void sd_event_source_unrefp(sd_event_source **s)
{
	if (s && *s)
		*s = sd_event_source_unref(*s);
}

#ifdef __cplusplus
}
#endif

#endif /* MIRA_SD_EVENT_H */
