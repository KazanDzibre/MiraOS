/*
 * mirad - Mira system supervisor.
 *
 * Started by BusyBox init as a respawn entry. Responsible for preparing
 * persistent state, then supervising mira-shell for the lifetime of the box.
 *
 * Design notes:
 *  - The shell is expected to run forever. If it dies we restart it, but with
 *    exponential backoff so a shell that crashes instantly on startup cannot
 *    spin the CPU. Backoff resets once the shell has stayed up long enough to
 *    be considered healthy.
 *  - If the shell is missing entirely (early bring-up, or a botched update)
 *    we say so on the console and keep waiting rather than exiting, so the
 *    box stays diagnosable over serial/SSH instead of looping through init.
 */

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MIRA_STATE_DIR "/var/lib/mira"
#define MIRA_SHELL_BIN "/usr/bin/mira-shell"

/* A shell that survives this long is considered healthy: reset the backoff. */
#define HEALTHY_UPTIME_SECS 30
#define BACKOFF_MIN_SECS 1
#define BACKOFF_MAX_SECS 30

static volatile sig_atomic_t g_terminate = 0;
static volatile sig_atomic_t g_child_pid = 0;

static void log_msg(const char *fmt, ...)
{
	va_list ap;
	time_t now = time(NULL);
	struct tm tm;
	char stamp[32] = "";

	if (gmtime_r(&now, &tm))
		strftime(stamp, sizeof(stamp), "%H:%M:%S", &tm);

	fprintf(stderr, "[mirad %s] ", stamp);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static void on_signal(int sig)
{
	g_terminate = sig;
	if (g_child_pid > 0)
		kill(g_child_pid, SIGTERM);
}

/* mkdir -p, tolerating components that already exist. */
static int mkdir_p(const char *path, mode_t mode)
{
	char buf[512];
	size_t len = strlen(path);

	if (len == 0 || len >= sizeof(buf)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	memcpy(buf, path, len + 1);

	for (char *p = buf + 1; *p; p++) {
		if (*p != '/')
			continue;
		*p = '\0';
		if (mkdir(buf, mode) != 0 && errno != EEXIST)
			return -1;
		*p = '/';
	}
	if (mkdir(buf, mode) != 0 && errno != EEXIST)
		return -1;
	return 0;
}

/*
 * The root filesystem is read-only; everything mutable lives on the data
 * partition. Create the directories the shell expects so it never has to
 * handle a half-provisioned state directory.
 */
static void prepare_state(void)
{
	static const char *dirs[] = {
		MIRA_STATE_DIR,
		MIRA_STATE_DIR "/config",
		MIRA_STATE_DIR "/cache",
		MIRA_STATE_DIR "/netbird",
	};

	for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		if (mkdir_p(dirs[i], 0755) != 0)
			log_msg("warning: cannot create %s: %s", dirs[i], strerror(errno));
	}
}

/* Sleep that gives up early if we have been asked to shut down. */
static void interruptible_sleep(unsigned secs)
{
	for (unsigned i = 0; i < secs && !g_terminate; i++)
		sleep(1);
}

/* Run mira-shell to completion. Returns its raw wait status, or -1 to stop. */
static int run_shell(void)
{
	pid_t pid = fork();

	if (pid < 0) {
		log_msg("fork failed: %s", strerror(errno));
		return -1;
	}

	if (pid == 0) {
		execl(MIRA_SHELL_BIN, "mira-shell", (char *)NULL);
		/* Only reached if exec failed. */
		fprintf(stderr, "[mirad] exec %s: %s\n", MIRA_SHELL_BIN, strerror(errno));
		_exit(127);
	}

	g_child_pid = pid;

	int status = 0;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno == EINTR)
			continue;
		log_msg("waitpid failed: %s", strerror(errno));
		g_child_pid = 0;
		return -1;
	}

	g_child_pid = 0;
	return status;
}

static void describe_exit(int status)
{
	if (WIFEXITED(status))
		log_msg("mira-shell exited with code %d", WEXITSTATUS(status));
	else if (WIFSIGNALED(status))
		log_msg("mira-shell killed by signal %d", WTERMSIG(status));
	else
		log_msg("mira-shell terminated (status 0x%x)", status);
}

int main(void)
{
	struct sigaction sa;
	unsigned backoff = BACKOFF_MIN_SECS;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	log_msg("starting");
	prepare_state();

	while (!g_terminate) {
		if (access(MIRA_SHELL_BIN, X_OK) != 0) {
			/*
			 * No shell installed. This is expected during early bring-up
			 * and possible after a bad update, so hold rather than exit:
			 * init would just respawn us into a tight loop.
			 */
			log_msg("%s not present or not executable - waiting", MIRA_SHELL_BIN);
			interruptible_sleep(BACKOFF_MAX_SECS);
			continue;
		}

		time_t started = time(NULL);
		log_msg("launching mira-shell");

		int status = run_shell();
		if (status < 0)
			break;

		if (g_terminate)
			break;

		describe_exit(status);

		/* A shell that stayed up is not a crash loop; forgive the backoff. */
		if (time(NULL) - started >= HEALTHY_UPTIME_SECS)
			backoff = BACKOFF_MIN_SECS;

		log_msg("restarting in %us", backoff);
		interruptible_sleep(backoff);

		backoff *= 2;
		if (backoff > BACKOFF_MAX_SECS)
			backoff = BACKOFF_MAX_SECS;
	}

	log_msg("shutting down (signal %d)", (int)g_terminate);
	return 0;
}
