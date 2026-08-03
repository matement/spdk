#include "spdk/stdinc.h"
#include "spdk/thread.h"
#include "spdk/bdev.h"
#include "spdk/env.h"
#include "spdk/event.h"
#include "spdk/log.h"
#include "spdk/string.h"
#include "spdk/bdev_zone.h"


static char *g_bdev_name = "Malloc0";

struct context_t {
	struct spdk_bdev *bdev;
	struct spdk_bdev_desc *bdev_desc;
	struct spdk_io_channel *bdev_io_channel;
	char *buff;
	uint32_t buff_size;
	char *bdev_name;
	char user_input[256];
	struct spdk_bdev_io_wait_entry bdev_io_wait;
};



static void
io_usage(void)
{
	printf(" -b <bdev>                 name of the bdev to use\n");
}

static int
io_parse_arg(int ch, char *arg)
{
	switch (ch) {
	case 'b':
		g_bdev_name = arg;
		break;
	default:
		return -EINVAL;
	}
	return 0;
}
static void
read_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg)
{
	struct context_t *context = cb_arg;

	if (success) {
		SPDK_NOTICELOG("Read string from bdev : %s\n", context->buff);
	} else {
		SPDK_ERRLOG("bdev io read error\n");
	}

	/* Complete the bdev io and close the channel */
	spdk_bdev_free_io(bdev_io);
	spdk_put_io_channel(context->bdev_io_channel);
	spdk_bdev_close(context->bdev_desc);
	SPDK_NOTICELOG("Stopping app\n");
	spdk_app_stop(success ? 0 : -1);
}

void io_read(void *arg)
{
	struct context_t *context = arg;
	int rc = 0;

	SPDK_NOTICELOG("Reading io\n");
	rc = spdk_bdev_read(context->bdev_desc, context->bdev_io_channel,
			    context->buff, 0, context->buff_size, read_complete,
			    context);

	if (rc == -ENOMEM) {
		SPDK_NOTICELOG("Queueing io\n");
		/* In case we cannot perform I/O now, queue I/O */
		context->bdev_io_wait.bdev = context->bdev;
		context->bdev_io_wait.cb_fn = io_read;
		context->bdev_io_wait.cb_arg = context;
		spdk_bdev_queue_io_wait(context->bdev, context->bdev_io_channel,
					&context->bdev_io_wait);
	} else if (rc) {
		SPDK_ERRLOG("%s error while reading from bdev: %d\n", spdk_strerror(-rc), rc);
		spdk_put_io_channel(context->bdev_io_channel);
		spdk_bdev_close(context->bdev_desc);
		spdk_app_stop(-1);
	}
}
static void write_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg){
	struct context_t *context = cb_arg;

	/* Complete the I/O */
	spdk_bdev_free_io(bdev_io);

	if (success) {
		SPDK_NOTICELOG("bdev io write completed successfully\n");
	} else {
		SPDK_ERRLOG("bdev io write error: %d\n", EIO);
		spdk_put_io_channel(context->bdev_io_channel);
		spdk_bdev_close(context->bdev_desc);
		spdk_app_stop(-1);
		return;
	}

	/* Zero the buffer so that we can use it for reading */
	memset(context->buff, 0, context->buff_size);

	io_read(context);
}

static void
io_write(void *arg)
{
	struct context_t *context = arg;
	int rc = 0;

	SPDK_NOTICELOG("Writing to the bdev\n");
	rc = spdk_bdev_write(context->bdev_desc, context->bdev_io_channel,
			     context->buff, 0, context->buff_size, write_complete,
			     context);

	if (rc == -ENOMEM) {
		SPDK_NOTICELOG("Queueing io\n");
		/* In case we cannot perform I/O now, queue I/O */
		context->bdev_io_wait.bdev = context->bdev;
		context->bdev_io_wait.cb_fn = io_write;
		context->bdev_io_wait.cb_arg = context;
		spdk_bdev_queue_io_wait(context->bdev, context->bdev_io_channel,
					&context->bdev_io_wait);
	} else if (rc) {
		SPDK_ERRLOG("%s error while writing to bdev: %d\n", spdk_strerror(-rc), rc);
		spdk_put_io_channel(context->bdev_io_channel);
		spdk_bdev_close(context->bdev_desc);
		spdk_app_stop(-1);
	}
}

static void
bdev_event_cb(enum spdk_bdev_event_type type, struct spdk_bdev *bdev,
		    void *event_ctx)
{
	SPDK_NOTICELOG("Unsupported bdev event: type %d\n", type);
}


static void
io_start(void *arg1)
{
	struct context_t *context = arg1;
	uint32_t buf_align;
	int rc = 0;
	context->bdev = NULL;
	context->bdev_desc = NULL;

	SPDK_NOTICELOG("Successfully started the application\n");

	/*
	 * There can be many bdevs configured, but this application will only use
	 * the one input by the user at runtime.
	 *
	 * Open the bdev by calling spdk_bdev_open_ext() with its name.
	 * The function will return a descriptor
	 */
	SPDK_NOTICELOG("Opening the bdev %s\n", context->bdev_name);
	rc = spdk_bdev_open_ext(context->bdev_name, true, bdev_event_cb, NULL,
				&context->bdev_desc);
	if (rc) {
		SPDK_ERRLOG("Could not open bdev: %s\n", context->bdev_name);
		spdk_app_stop(-1);
		return;
	}

	/* A bdev pointer is valid while the bdev is opened. */
	context->bdev = spdk_bdev_desc_get_bdev(context->bdev_desc);


	SPDK_NOTICELOG("Opening io channel\n");
	/* Open I/O channel */
	context->bdev_io_channel = spdk_bdev_get_io_channel(context->bdev_desc);
	if (context->bdev_io_channel == NULL) {
		SPDK_ERRLOG("Could not create bdev I/O channel!!\n");
		spdk_bdev_close(context->bdev_desc);
		spdk_app_stop(-1);
		return;
	}

	/* Allocate memory for the write buffer.
	 * Initialize the write buffer with the string "Hello World!"
	 */
	context->buff_size = spdk_bdev_get_block_size(context->bdev) *
				   spdk_bdev_get_write_unit_size(context->bdev);
	buf_align = spdk_bdev_get_buf_align(context->bdev);
	context->buff = spdk_dma_zmalloc(context->buff_size, buf_align, NULL);
	if (!context->buff) {
		SPDK_ERRLOG("Failed to allocate buffer\n");
		spdk_put_io_channel(context->bdev_io_channel);
		spdk_bdev_close(context->bdev_desc);
		spdk_app_stop(-1);
		return;
	}
	snprintf(context->buff, context->buff_size, "%s\n", context->user_input);

	

	io_write(context);
}


int main(int argc, char *argv[]){
	struct spdk_app_opts opts = {};
	int rc = 0;
	struct context_t context = {};

	spdk_app_opts_init(&opts, sizeof(opts));
	opts.name = "io_app";
	opts.rpc_addr = NULL;

	if((rc = spdk_app_parse_args(argc, argv, &opts, "b:", NULL, io_parse_arg, io_usage)) != SPDK_APP_PARSE_ARGS_SUCCESS){
		exit(rc);
	}
	context.bdev_name = g_bdev_name;

	//input before calling spdk

	printf("ENTER INPUT:\t");
	if(fgets(context.user_input, sizeof(context.user_input), stdin) == NULL){
		fprintf(stdout, "Failed to get input\n");
		return 1;
	}

	context.user_input[strcspn(context.user_input, "\n")] = '\0';	//remove newline

	rc = spdk_app_start(&opts, io_start, &context);
}