/* Exercises the behaviours flutter-pi actually relies on. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

/* Deliberately does NOT include <sys/epoll.h>: callers get EPOLLIN and friends
 * from sd-event.h, exactly as they do with systemd's header. This file failing
 * to compile is the regression test for that. */
#include "systemd/sd-event.h"

static int failures;
static char order[64];
static size_t order_len;

#define CHECK(cond, ...)                                   \
	do {                                                   \
		if (!(cond)) {                                      \
			printf("  FAIL: ");                             \
			printf(__VA_ARGS__);                             \
			printf("\n");                                    \
			failures++;                                      \
		}                                                    \
	} while (0)

static void note(char c) { if (order_len < sizeof order - 1) order[order_len++] = c; }
static void reset(void) { memset(order, 0, sizeof order); order_len = 0; }

static uint64_t mono_usec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static int on_defer(sd_event_source *s, void *ud) { (void)s; note(*(char *)ud); return 0; }
static int on_time(sd_event_source *s, uint64_t usec, void *ud) { (void)s; (void)usec; note(*(char *)ud); return 0; }
static int on_io(sd_event_source *s, int fd, uint32_t revents, void *ud)
{
	char buf[8];
	(void)s;
	CHECK(revents & EPOLLIN, "io source woke without EPOLLIN");
	(void)!read(fd, buf, sizeof buf);
	note(*(char *)ud);
	return 0;
}

/* Drives the loop exactly the way flutter-pi's evloop_run does. */
static void pump(sd_event *e, int max_iterations)
{
	int fd = sd_event_get_fd(e);

	for (int i = 0; i < max_iterations; i++) {
		int state = sd_event_get_state(e);

		if (state == SD_EVENT_FINISHED)
			return;
		if (state == SD_EVENT_INITIAL) {
			CHECK(sd_event_prepare(e) >= 0, "prepare failed");
		} else if (state == SD_EVENT_ARMED) {
			fd_set rfds;
			struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };

			FD_ZERO(&rfds);
			FD_SET(fd, &rfds);
			if (select(fd + 1, &rfds, NULL, NULL, &tv) <= 0)
				return; /* nothing more to do */
			CHECK(sd_event_wait(e, 0) >= 0, "wait failed");
		} else if (state == SD_EVENT_PENDING) {
			CHECK(sd_event_dispatch(e) >= 0, "dispatch failed");
		} else {
			return;
		}
	}
}

static void test_defer_oneshot(void)
{
	sd_event *e = NULL;
	char a = 'a';

	printf("defer fires once and then disables itself\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	CHECK(sd_event_add_defer(e, NULL, on_defer, &a) == 0, "add_defer");
	pump(e, 20);
	CHECK(strcmp(order, "a") == 0, "expected 'a', got '%s'", order);
	sd_event_unref(e);
}

static void test_priority_order(void)
{
	sd_event *e = NULL;
	sd_event_source *s1, *s2, *s3;
	char a = 'a', b = 'b', c = 'c';

	printf("lower priority value dispatches first\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, &s1, on_defer, &a);
	sd_event_add_defer(e, &s2, on_defer, &b);
	sd_event_add_defer(e, &s3, on_defer, &c);
	sd_event_source_set_priority(s1, 2);
	sd_event_source_set_priority(s2, 0);
	sd_event_source_set_priority(s3, 1);
	pump(e, 40);
	CHECK(strcmp(order, "bca") == 0, "expected 'bca', got '%s'", order);
	sd_event_source_unref(s1);
	sd_event_source_unref(s2);
	sd_event_source_unref(s3);
	sd_event_unref(e);
}

static void test_fifo_within_priority(void)
{
	sd_event *e = NULL;
	char a = 'a', b = 'b', c = 'c';

	printf("equal priorities keep insertion order (platform task FIFO)\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, NULL, on_defer, &a);
	sd_event_add_defer(e, NULL, on_defer, &b);
	sd_event_add_defer(e, NULL, on_defer, &c);
	pump(e, 40);
	CHECK(strcmp(order, "abc") == 0, "expected 'abc', got '%s'", order);
	sd_event_unref(e);
}

static void test_increasing_priority_fifo(void)
{
	sd_event *e = NULL;
	sd_event_source *s;
	char a = 'a', b = 'b', c = 'c';
	int counter = 0;

	/* Exactly what flutter-pi does when posting a platform task: take the
	 * handle, set an ever-increasing priority, and deliberately not unref on
	 * the success path - the loop is left holding it. */
	printf("flutter-pi's pattern: increasing priority == FIFO\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, &s, on_defer, &a);
	sd_event_source_set_priority(s, counter++);
	sd_event_add_defer(e, &s, on_defer, &b);
	sd_event_source_set_priority(s, counter++);
	sd_event_add_defer(e, &s, on_defer, &c);
	sd_event_source_set_priority(s, counter++);
	pump(e, 40);
	CHECK(strcmp(order, "abc") == 0, "expected 'abc', got '%s'", order);
	sd_event_unref(e);
}

static void test_timers(void)
{
	sd_event *e = NULL;
	uint64_t now;
	char a = 'a', b = 'b';

	printf("timers fire in deadline order, not insertion order\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	now = mono_usec();
	/* 'b' is added first but is due later. */
	sd_event_add_time(e, NULL, CLOCK_MONOTONIC, now + 120000, 0, on_time, &b);
	sd_event_add_time(e, NULL, CLOCK_MONOTONIC, now + 20000, 0, on_time, &a);
	pump(e, 60);
	CHECK(strcmp(order, "ab") == 0, "expected 'ab', got '%s'", order);
	sd_event_unref(e);
}

static void test_io(void)
{
	sd_event *e = NULL;
	int fds[2];
	char a = 'a';

	printf("io source wakes the loop through the epoll fd\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	CHECK(pipe(fds) == 0, "pipe");
	reset();
	sd_event_add_io(e, NULL, fds[0], EPOLLIN, on_io, &a);
	CHECK(write(fds[1], "x", 1) == 1, "write");
	pump(e, 20);
	CHECK(strcmp(order, "a") == 0, "expected 'a', got '%s'", order);
	close(fds[0]);
	close(fds[1]);
	sd_event_unref(e);
}

static int on_exit_cb(sd_event_source *s, void *ud)
{
	sd_event *e = ud;
	(void)s;
	note('x');
	sd_event_exit(e, 7);
	return 0;
}

static void test_exit(void)
{
	sd_event *e = NULL;
	int code = 0;

	printf("exit from inside a callback finishes the loop\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, NULL, on_exit_cb, e);
	pump(e, 20);
	CHECK(strcmp(order, "x") == 0, "expected 'x', got '%s'", order);
	CHECK(sd_event_get_state(e) == SD_EVENT_FINISHED, "loop did not finish");
	sd_event_get_exit_code(e, &code);
	CHECK(code == 7, "exit code %d, expected 7", code);
	sd_event_unref(e);
}

static int on_self_unref(sd_event_source *s, void *ud)
{
	note(*(char *)ud);
	sd_event_source_unref(s); /* a callback is entitled to drop its own source */
	return 0;
}

static void test_self_unref(void)
{
	sd_event *e = NULL;
	sd_event_source *s;
	char a = 'a';

	printf("a source may unref itself from inside its own callback\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, &s, on_self_unref, &a);
	pump(e, 20);
	CHECK(strcmp(order, "a") == 0, "expected 'a', got '%s'", order);
	sd_event_unref(e);
}

static void test_floating(void)
{
	sd_event *e = NULL;
	sd_event_source *s;
	char a = 'a';

	printf("a floating source survives the caller dropping its handle\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, &s, on_defer, &a);
	sd_event_source_set_floating(s, 1);
	pump(e, 20);
	CHECK(strcmp(order, "a") == 0, "expected 'a', got '%s'", order);
	sd_event_unref(e);
}

static void test_unref_cancels(void)
{
	sd_event *e = NULL;
	sd_event_source *s;
	char a = 'a', b = 'b';

	printf("dropping the last handle cancels a source before it fires\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, &s, on_defer, &a);
	sd_event_source_unref(s); /* non-floating: this destroys it */
	sd_event_add_defer(e, NULL, on_defer, &b);
	pump(e, 20);
	CHECK(strcmp(order, "b") == 0, "expected 'b', got '%s'", order);
	sd_event_unref(e);
}

static void test_disable_prevents_dispatch(void)
{
	sd_event *e = NULL;
	sd_event_source *s;
	char a = 'a', b = 'b';

	printf("a disabled source does not fire\n");
	CHECK(sd_event_new(&e) == 0, "sd_event_new");
	reset();
	sd_event_add_defer(e, &s, on_defer, &a);
	sd_event_source_set_enabled(s, SD_EVENT_OFF);
	sd_event_add_defer(e, NULL, on_defer, &b);
	pump(e, 20);
	CHECK(strcmp(order, "b") == 0, "expected 'b', got '%s'", order);
	sd_event_source_unref(s);
	sd_event_unref(e);
}

int main(void)
{
	test_defer_oneshot();
	test_priority_order();
	test_fifo_within_priority();
	test_increasing_priority_fifo();
	test_timers();
	test_io();
	test_exit();
	test_self_unref();
	test_floating();
	test_unref_cancels();
	test_disable_prevents_dispatch();

	if (failures == 0) {
		printf("\nall sd-event shim tests passed\n");
		return 0;
	}
	printf("\n%d check(s) failed\n", failures);
	return 1;
}
