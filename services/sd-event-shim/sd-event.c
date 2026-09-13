/*
 * A small, self-contained implementation of the sd-event subset flutter-pi uses.
 *
 * Shape of the loop, which is the part that matters and the part a naive
 * implementation gets wrong:
 *
 *   INITIAL --prepare()--> ARMED --(caller selects on get_fd())--> wait()
 *          \                                                        |
 *           `--(something already pending)--> PENDING <-------------'
 *                                               |
 *                                           dispatch() --> INITIAL
 *
 * Everything waits on one epoll fd so the caller can select() on it, and timers
 * live on a timerfd inside that same epoll set - without which an armed loop
 * with only timers pending would block forever.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <unistd.h>

#include "systemd/sd-event.h"

#define MAX_EPOLL_EVENTS 32

enum source_type { SOURCE_IO, SOURCE_TIME, SOURCE_DEFER };

struct sd_event_source {
	sd_event *event;
	enum source_type type;

	int enabled;
	int64_t priority;
	uint64_t seq; /* FIFO tie-break within one priority */
	bool pending;
	bool floating;
	bool attached;
	unsigned refs; /* caller-held references only */

	void *userdata;

	/* io */
	int fd;
	int owned_fd; /* a dup(), when the same fd is registered twice */
	uint32_t events;
	uint32_t revents;
	sd_event_io_handler_t io_cb;

	/* time */
	clockid_t clock;
	uint64_t usec;
	sd_event_time_handler_t time_cb;

	/* defer */
	sd_event_handler_t defer_cb;

	struct sd_event_source *prev, *next;
};

struct sd_event {
	unsigned refs;
	int epoll_fd;
	int timer_fd;
	int state;
	int exit_code;
	bool exiting;
	uint64_t next_seq;
	pthread_mutex_t lock;
	struct sd_event_source *sources;
};

/* Distinguishes the timerfd from a source pointer in epoll_event.data.ptr. */
static const char timer_marker;

static uint64_t now_usec(clockid_t clock)
{
	struct timespec ts;

	if (clock_gettime(clock, &ts) < 0)
		return 0;
	return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

/* ---- source list ---------------------------------------------------- */

static void source_link(sd_event *e, sd_event_source *s)
{
	s->prev = NULL;
	s->next = e->sources;
	if (e->sources)
		e->sources->prev = s;
	e->sources = s;
	s->attached = true;
}

static void source_unlink(sd_event_source *s)
{
	if (!s->attached)
		return;
	if (s->prev)
		s->prev->next = s->next;
	else
		s->event->sources = s->next;
	if (s->next)
		s->next->prev = s->prev;
	s->prev = s->next = NULL;
	s->attached = false;
}

static void source_epoll_del(sd_event_source *s)
{
	if (s->type != SOURCE_IO)
		return;
	epoll_ctl(s->event->epoll_fd, EPOLL_CTL_DEL, s->owned_fd >= 0 ? s->owned_fd : s->fd, NULL);
}

static int source_epoll_sync(sd_event_source *s)
{
	struct epoll_event ev;
	int fd;

	if (s->type != SOURCE_IO)
		return 0;

	fd = s->owned_fd >= 0 ? s->owned_fd : s->fd;
	memset(&ev, 0, sizeof ev);
	ev.events = s->enabled == SD_EVENT_OFF ? 0 : s->events;
	ev.data.ptr = s;

	if (epoll_ctl(s->event->epoll_fd, EPOLL_CTL_MOD, fd, &ev) == 0)
		return 0;
	if (errno != ENOENT)
		return -errno;
	return epoll_ctl(s->event->epoll_fd, EPOLL_CTL_ADD, fd, &ev) == 0 ? 0 : -errno;
}

static void source_free(sd_event_source *s)
{
	source_epoll_del(s);
	source_unlink(s);
	if (s->owned_fd >= 0)
		close(s->owned_fd);
	free(s);
}

/* Drops a source once nobody holds it: neither a caller reference nor the loop
 * itself by way of the floating flag. */
static void source_maybe_free(sd_event_source *s)
{
	if (s->refs == 0 && !s->floating)
		source_free(s);
}

/* ---- loop ----------------------------------------------------------- */

int sd_event_new(sd_event **ret)
{
	sd_event *e;
	struct epoll_event ev;

	if (!ret)
		return -EINVAL;

	e = calloc(1, sizeof *e);
	if (!e)
		return -ENOMEM;

	e->refs = 1;
	e->state = SD_EVENT_INITIAL;
	e->epoll_fd = -1;
	e->timer_fd = -1;
	pthread_mutex_init(&e->lock, NULL);

	e->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
	if (e->epoll_fd < 0)
		goto fail;

	e->timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	if (e->timer_fd < 0)
		goto fail;

	memset(&ev, 0, sizeof ev);
	ev.events = EPOLLIN;
	ev.data.ptr = (void *)&timer_marker;
	if (epoll_ctl(e->epoll_fd, EPOLL_CTL_ADD, e->timer_fd, &ev) < 0)
		goto fail;

	*ret = e;
	return 0;

fail: {
	int saved = -errno;

	if (e->timer_fd >= 0)
		close(e->timer_fd);
	if (e->epoll_fd >= 0)
		close(e->epoll_fd);
	pthread_mutex_destroy(&e->lock);
	free(e);
	return saved;
}
}

sd_event *sd_event_ref(sd_event *e)
{
	if (!e)
		return NULL;
	pthread_mutex_lock(&e->lock);
	e->refs++;
	pthread_mutex_unlock(&e->lock);
	return e;
}

sd_event *sd_event_unref(sd_event *e)
{
	bool destroy;

	if (!e)
		return NULL;

	pthread_mutex_lock(&e->lock);
	destroy = (--e->refs == 0);
	pthread_mutex_unlock(&e->lock);

	if (!destroy)
		return NULL;

	while (e->sources) {
		sd_event_source *s = e->sources;

		s->refs = 0;
		s->floating = false;
		source_free(s);
	}

	close(e->timer_fd);
	close(e->epoll_fd);
	pthread_mutex_destroy(&e->lock);
	free(e);
	return NULL;
}

int sd_event_get_fd(sd_event *e)
{
	return e ? e->epoll_fd : -EINVAL;
}

int sd_event_get_state(sd_event *e)
{
	int state;

	if (!e)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);
	/* No exit sources are supported, so EXITING has nothing to do and the
	 * loop goes straight to FINISHED. */
	state = e->exiting ? SD_EVENT_FINISHED : e->state;
	pthread_mutex_unlock(&e->lock);
	return state;
}

int sd_event_exit(sd_event *e, int code)
{
	if (!e)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);
	e->exiting = true;
	e->exit_code = code;
	pthread_mutex_unlock(&e->lock);
	return 0;
}

int sd_event_get_exit_code(sd_event *e, int *ret)
{
	if (!e || !ret)
		return -EINVAL;
	pthread_mutex_lock(&e->lock);
	*ret = e->exit_code;
	pthread_mutex_unlock(&e->lock);
	return 0;
}

/* ---- adding sources -------------------------------------------------- */

static int source_add(sd_event *e, sd_event_source **ret, enum source_type type,
		      sd_event_source **out)
{
	sd_event_source *s;

	s = calloc(1, sizeof *s);
	if (!s)
		return -ENOMEM;

	s->event = e;
	s->type = type;
	s->priority = SD_EVENT_PRIORITY_NORMAL;
	s->seq = e->next_seq++;
	s->fd = -1;
	s->owned_fd = -1;

	/* With no out-parameter the caller never gets a handle, so the loop owns
	 * the source outright - that is what sd-event calls floating. */
	if (ret) {
		s->refs = 1;
		s->floating = false;
	} else {
		s->refs = 0;
		s->floating = true;
	}

	source_link(e, s);
	*out = s;
	if (ret)
		*ret = s;
	return 0;
}

int sd_event_add_io(sd_event *e, sd_event_source **ret, int fd, uint32_t events,
		    sd_event_io_handler_t callback, void *userdata)
{
	sd_event_source *s;
	int r;

	if (!e || fd < 0 || !callback)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);

	r = source_add(e, ret, SOURCE_IO, &s);
	if (r < 0) {
		pthread_mutex_unlock(&e->lock);
		return r;
	}

	s->fd = fd;
	s->events = events;
	s->io_cb = callback;
	s->userdata = userdata;
	s->enabled = SD_EVENT_ON;

	r = source_epoll_sync(s);
	if (r == -EEXIST) {
		/* epoll refuses the same fd twice. Register a private dup so two
		 * sources can watch one descriptor. */
		s->owned_fd = dup(fd);
		if (s->owned_fd < 0)
			r = -errno;
		else
			r = source_epoll_sync(s);
	}
	if (r < 0) {
		source_free(s);
		if (ret)
			*ret = NULL;
		pthread_mutex_unlock(&e->lock);
		return r;
	}

	pthread_mutex_unlock(&e->lock);
	return 0;
}

int sd_event_add_time(sd_event *e, sd_event_source **ret, clockid_t clock,
		      uint64_t usec, uint64_t accuracy,
		      sd_event_time_handler_t callback, void *userdata)
{
	sd_event_source *s;
	int r;

	(void)accuracy; /* the timerfd gives us better resolution than we need */

	if (!e || !callback)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);
	r = source_add(e, ret, SOURCE_TIME, &s);
	if (r < 0) {
		pthread_mutex_unlock(&e->lock);
		return r;
	}

	s->clock = clock;
	s->usec = usec;
	s->time_cb = callback;
	s->userdata = userdata;
	s->enabled = SD_EVENT_ONESHOT;
	pthread_mutex_unlock(&e->lock);
	return 0;
}

int sd_event_add_defer(sd_event *e, sd_event_source **ret,
		       sd_event_handler_t callback, void *userdata)
{
	sd_event_source *s;
	int r;

	if (!e || !callback)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);
	r = source_add(e, ret, SOURCE_DEFER, &s);
	if (r < 0) {
		pthread_mutex_unlock(&e->lock);
		return r;
	}

	s->defer_cb = callback;
	s->userdata = userdata;
	s->enabled = SD_EVENT_ONESHOT;
	pthread_mutex_unlock(&e->lock);
	return 0;
}

/* ---- source accessors ------------------------------------------------ */

sd_event_source *sd_event_source_ref(sd_event_source *s)
{
	if (!s)
		return NULL;
	pthread_mutex_lock(&s->event->lock);
	s->refs++;
	pthread_mutex_unlock(&s->event->lock);
	return s;
}

sd_event_source *sd_event_source_unref(sd_event_source *s)
{
	sd_event *e;

	if (!s)
		return NULL;

	e = s->event;
	pthread_mutex_lock(&e->lock);
	if (s->refs > 0)
		s->refs--;
	source_maybe_free(s);
	pthread_mutex_unlock(&e->lock);
	return NULL;
}

sd_event_source *sd_event_source_disable_unref(sd_event_source *s)
{
	if (!s)
		return NULL;
	sd_event_source_set_enabled(s, SD_EVENT_OFF);
	return sd_event_source_unref(s);
}

int sd_event_source_set_enabled(sd_event_source *s, int enabled)
{
	int r = 0;

	if (!s)
		return -EINVAL;

	pthread_mutex_lock(&s->event->lock);
	s->enabled = enabled;
	if (enabled == SD_EVENT_OFF)
		s->pending = false;
	r = source_epoll_sync(s);
	pthread_mutex_unlock(&s->event->lock);
	return r;
}

int sd_event_source_get_enabled(sd_event_source *s, int *ret)
{
	if (!s)
		return -EINVAL;
	if (ret)
		*ret = s->enabled;
	return 0;
}

int sd_event_source_set_priority(sd_event_source *s, int64_t priority)
{
	if (!s)
		return -EINVAL;
	pthread_mutex_lock(&s->event->lock);
	s->priority = priority;
	pthread_mutex_unlock(&s->event->lock);
	return 0;
}

int sd_event_source_set_floating(sd_event_source *s, int b)
{
	if (!s)
		return -EINVAL;

	pthread_mutex_lock(&s->event->lock);
	if (b && !s->floating) {
		/* The loop takes over the caller's reference. */
		s->floating = true;
		if (s->refs > 0)
			s->refs--;
	} else if (!b && s->floating) {
		s->floating = false;
		s->refs++;
	}
	pthread_mutex_unlock(&s->event->lock);
	return 0;
}

int sd_event_source_set_time(sd_event_source *s, uint64_t usec)
{
	if (!s || s->type != SOURCE_TIME)
		return -EINVAL;
	pthread_mutex_lock(&s->event->lock);
	s->usec = usec;
	pthread_mutex_unlock(&s->event->lock);
	return 0;
}

int sd_event_source_set_userdata(sd_event_source *s, void *userdata)
{
	if (!s)
		return -EINVAL;
	s->userdata = userdata;
	return 0;
}

void *sd_event_source_get_userdata(sd_event_source *s)
{
	return s ? s->userdata : NULL;
}

int sd_event_source_get_pending(sd_event_source *s)
{
	if (!s)
		return -EINVAL;
	return s->pending ? 1 : 0;
}

/* ---- prepare / wait / dispatch --------------------------------------- */

static bool any_pending(sd_event *e)
{
	for (sd_event_source *s = e->sources; s; s = s->next)
		if (s->pending)
			return true;
	return false;
}

/* Arms the timerfd for the soonest enabled time source, so an armed loop with
 * only timers outstanding still wakes the caller's select(). */
static void arm_timer(sd_event *e)
{
	struct itimerspec its;
	bool have = false;
	uint64_t soonest = 0;

	for (sd_event_source *s = e->sources; s; s = s->next) {
		if (s->type != SOURCE_TIME || s->enabled == SD_EVENT_OFF || s->pending)
			continue;
		if (!have || s->usec < soonest) {
			soonest = s->usec;
			have = true;
		}
	}

	memset(&its, 0, sizeof its);
	if (have) {
		uint64_t now = now_usec(CLOCK_MONOTONIC);
		uint64_t delta = soonest > now ? soonest - now : 1; /* 0 disarms */

		its.it_value.tv_sec = (time_t)(delta / 1000000u);
		its.it_value.tv_nsec = (long)((delta % 1000000u) * 1000u);
	}
	timerfd_settime(e->timer_fd, 0, &its, NULL);
}

int sd_event_prepare(sd_event *e)
{
	if (!e)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);
	if (e->exiting) {
		pthread_mutex_unlock(&e->lock);
		return 0;
	}

	/* An enabled defer source is pending by definition: it runs on the next
	 * turn of the loop rather than waiting for anything. */
	for (sd_event_source *s = e->sources; s; s = s->next)
		if (s->type == SOURCE_DEFER && s->enabled != SD_EVENT_OFF)
			s->pending = true;

	/* Timers that are already due should not cost a trip through select(). */
	{
		uint64_t now = now_usec(CLOCK_MONOTONIC);

		for (sd_event_source *s = e->sources; s; s = s->next)
			if (s->type == SOURCE_TIME && s->enabled != SD_EVENT_OFF && s->usec <= now)
				s->pending = true;
	}

	arm_timer(e);

	if (any_pending(e)) {
		e->state = SD_EVENT_PENDING;
		pthread_mutex_unlock(&e->lock);
		return 1;
	}

	e->state = SD_EVENT_ARMED;
	pthread_mutex_unlock(&e->lock);
	return 0;
}

int sd_event_wait(sd_event *e, uint64_t timeout_usec)
{
	struct epoll_event events[MAX_EPOLL_EVENTS];
	int timeout_ms;
	int n;

	if (!e)
		return -EINVAL;

	if (timeout_usec == (uint64_t)-1)
		timeout_ms = -1;
	else if (timeout_usec > (uint64_t)INT32_MAX * 1000u)
		timeout_ms = INT32_MAX;
	else
		timeout_ms = (int)(timeout_usec / 1000u);

	do {
		n = epoll_wait(e->epoll_fd, events, MAX_EPOLL_EVENTS, timeout_ms);
	} while (n < 0 && errno == EINTR);

	if (n < 0)
		return -errno;

	pthread_mutex_lock(&e->lock);

	for (int i = 0; i < n; i++) {
		if (events[i].data.ptr == (void *)&timer_marker) {
			uint64_t ticks;
			uint64_t now;

			while (read(e->timer_fd, &ticks, sizeof ticks) > 0)
				; /* drain */

			now = now_usec(CLOCK_MONOTONIC);
			for (sd_event_source *s = e->sources; s; s = s->next)
				if (s->type == SOURCE_TIME && s->enabled != SD_EVENT_OFF && s->usec <= now)
					s->pending = true;
			continue;
		}

		sd_event_source *s = events[i].data.ptr;

		/* The source may have been freed inside an earlier callback in
		 * this same batch; only trust it if it is still linked. */
		bool alive = false;

		for (sd_event_source *t = e->sources; t; t = t->next)
			if (t == s) {
				alive = true;
				break;
			}
		if (!alive || s->enabled == SD_EVENT_OFF)
			continue;

		s->revents = events[i].events;
		s->pending = true;
	}

	if (any_pending(e)) {
		e->state = SD_EVENT_PENDING;
		pthread_mutex_unlock(&e->lock);
		return 1;
	}

	e->state = SD_EVENT_INITIAL;
	pthread_mutex_unlock(&e->lock);
	return 0;
}

int sd_event_dispatch(sd_event *e)
{
	sd_event_source *best = NULL;
	sd_event_source *s;
	int r = 0;

	if (!e)
		return -EINVAL;

	pthread_mutex_lock(&e->lock);

	if (e->exiting) {
		e->state = SD_EVENT_FINISHED;
		pthread_mutex_unlock(&e->lock);
		return 0;
	}

	/* Lowest priority value wins; within a priority, oldest first. That
	 * ordering is load-bearing - flutter-pi hands platform tasks an
	 * increasing priority precisely to get FIFO out of it. */
	for (s = e->sources; s; s = s->next) {
		if (!s->pending)
			continue;
		if (!best || s->priority < best->priority ||
		    (s->priority == best->priority && s->seq < best->seq))
			best = s;
	}

	if (!best) {
		e->state = SD_EVENT_INITIAL;
		pthread_mutex_unlock(&e->lock);
		return 1;
	}

	best->pending = false;
	if (best->enabled == SD_EVENT_ONESHOT) {
		best->enabled = SD_EVENT_OFF;
		source_epoll_sync(best);
	}

	/* Hold a reference across the callback: it is entitled to unref itself. */
	best->refs++;
	e->state = SD_EVENT_RUNNING;

	{
		enum source_type type = best->type;
		void *userdata = best->userdata;
		uint32_t revents = best->revents;
		int fd = best->fd;
		uint64_t usec = best->usec;
		sd_event_io_handler_t io_cb = best->io_cb;
		sd_event_time_handler_t time_cb = best->time_cb;
		sd_event_handler_t defer_cb = best->defer_cb;

		/* Callbacks re-enter to add and remove sources, so the lock must
		 * not be held while one runs. */
		pthread_mutex_unlock(&e->lock);

		switch (type) {
		case SOURCE_IO:
			r = io_cb(best, fd, revents, userdata);
			break;
		case SOURCE_TIME:
			r = time_cb(best, usec, userdata);
			break;
		case SOURCE_DEFER:
			r = defer_cb(best, userdata);
			break;
		}

		pthread_mutex_lock(&e->lock);
	}

	if (best->refs > 0)
		best->refs--;
	source_maybe_free(best);

	e->state = e->exiting ? SD_EVENT_FINISHED : SD_EVENT_INITIAL;
	{
		bool finished = e->exiting;

		pthread_mutex_unlock(&e->lock);
		if (r < 0)
			return r;
		return finished ? 0 : 1;
	}
}

int sd_event_run(sd_event *e, uint64_t timeout_usec)
{
	int r;

	r = sd_event_prepare(e);
	if (r < 0)
		return r;
	if (r == 0) {
		r = sd_event_wait(e, timeout_usec);
		if (r <= 0)
			return r;
	}
	return sd_event_dispatch(e);
}

int sd_event_loop(sd_event *e)
{
	int r;

	if (!e)
		return -EINVAL;

	while (sd_event_get_state(e) != SD_EVENT_FINISHED) {
		r = sd_event_run(e, (uint64_t)-1);
		if (r < 0)
			return r;
	}
	return e->exit_code;
}
