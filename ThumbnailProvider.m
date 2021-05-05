//
//  ThumbnailProvider.m
//  VideoThumbnailing
//
//  Copyright © 2021 Stephen Salerno. All rights reserved.
//

#import "ThumbnailProvider.h"
#import <UIKit/UIKit.h>

#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>

#define THUMBNAIL_POSITION_PERCENT 25
#define THUMBNAIL_ERROR(msg) [[NSError alloc] initWithDomain:@"VideoThumbnailing" code:100 userInfo:@{@"Error": msg}]

@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request completionHandler:(void (^)(QLThumbnailReply * _Nullable, NSError * _Nullable))handler {
    @synchronized (self) {
        CGSize maxSize = request.maximumSize;
        NSString *path = request.fileURL.path;
        char *cPath = strdup(path.fileSystemRepresentation);
        int ret;

        // Open file
        AVFormatContext *formatContext = NULL;
        ret = avformat_open_input(&formatContext, cPath, NULL, NULL);
        free(cPath);
        if (ret < 0) {
            handler(NULL, THUMBNAIL_ERROR(@"Couldn't open input stream"));
            return;
        }

        // Load media streams
        ret = avformat_find_stream_info(formatContext, NULL);
        if (ret < 0) {
            handler(NULL, THUMBNAIL_ERROR(@"Couldn't get stream info"));
            avformat_close_input(&formatContext);
            return;
        }

        // Find the main video stream
        AVCodec *decoder = NULL;
        int videoStreamId = -1;
        videoStreamId = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
        if (videoStreamId < 0) {
            handler(NULL, THUMBNAIL_ERROR(@"No video stream found"));
            avformat_close_input(&formatContext);
            return;
        }
        AVStream *videoStream = formatContext->streams[videoStreamId];

        // Open codec
        AVCodecContext *codecContext = avcodec_alloc_context3(decoder);
        avcodec_parameters_to_context(codecContext, videoStream->codecpar);
        codecContext->time_base = videoStream->time_base;
        enum AVPixelFormat pixelFormat = codecContext->pix_fmt;

        ret = avcodec_open2(codecContext, decoder, NULL);
        if (ret < 0 || pixelFormat == AV_PIX_FMT_NONE) {
            handler(NULL, THUMBNAIL_ERROR(@"Couldn't open codec"));
            avcodec_free_context(&codecContext);
            avformat_close_input(&formatContext);
            return;
        }

        // Allocate frame to decode to
        AVFrame *rawFrame = av_frame_alloc();
        if (rawFrame == NULL) {
            handler(NULL, THUMBNAIL_ERROR(@"Couldn't alloc frame"));
            avcodec_free_context(&codecContext);
            avformat_close_input(&formatContext);
            return;
        }

        // Seek to the point to capture thumbnail from
        int64_t duration = av_rescale_q(formatContext->duration, AV_TIME_BASE_Q, videoStream->time_base);
        int64_t seek_pos = (duration * THUMBNAIL_POSITION_PERCENT) / 100 + videoStream->start_time;

        avcodec_flush_buffers(codecContext);

        ret = av_seek_frame(formatContext, videoStreamId, seek_pos, AVSEEK_FLAG_BACKWARD);
        if (ret < 0) {
            handler(NULL, THUMBNAIL_ERROR(@"Seek failed"));
            avcodec_free_context(&codecContext);
            avformat_close_input(&formatContext);
            av_frame_free(&rawFrame);
            return;
        }

        avcodec_flush_buffers(codecContext);

        // Find the nearest video frame
        AVPacket packet;
        while(av_read_frame(formatContext, &packet) >= 0) {
            if (packet.stream_index == videoStreamId) {
                if (avcodec_send_packet(codecContext, &packet) < 0) {
                    break;
                }

                ret = avcodec_receive_frame(codecContext, rawFrame);
                if (ret < 0 || ret == AVERROR(EAGAIN)) {
                    av_frame_unref(rawFrame);
                    av_packet_unref(&packet);
                    continue;
                }
                break;
            }
            av_packet_unref(&packet);
        }

        avcodec_free_context(&codecContext);
        avformat_close_input(&formatContext);
        av_packet_unref(&packet);

        // Allocate frame for output
        __block AVFrame *outputFrame = av_frame_alloc();
        if (outputFrame == NULL) {
            handler(NULL, THUMBNAIL_ERROR(@"Couldn't alloc output frame"));
            avcodec_free_context(&codecContext);
            avformat_close_input(&formatContext);
            av_frame_free(&rawFrame);
            return;
        }
        int thumbWidth = maxSize.width * request.scale;
        int thumbHeight = thumbWidth / ((float)rawFrame->width / rawFrame->height);
        outputFrame->width = thumbWidth;
        outputFrame->height = thumbHeight;
        outputFrame->format = AV_PIX_FMT_RGBA;

        int size = av_image_get_buffer_size(outputFrame->format, thumbWidth, thumbHeight, 1);
        uint8_t *outputFrameBuffer = (uint8_t *)av_malloc(size);

        ret = av_image_fill_arrays(outputFrame->data,
                                   outputFrame->linesize,
                                   outputFrameBuffer,
                                   outputFrame->format,
                                   thumbWidth,
                                   thumbHeight,
                                   1);
        if (ret < 0) {
            handler(NULL, THUMBNAIL_ERROR(@"Couldn't fill output frame"));
            av_frame_free(&rawFrame);
            av_frame_free(&outputFrame);
            av_free(outputFrameBuffer);
            return;
        }

        // Create sws context for scaling
        struct SwsContext *swsContext = sws_getContext(rawFrame->width,
                                                       rawFrame->height,
                                                       rawFrame->format,
                                                       outputFrame->width,
                                                       outputFrame->height,
                                                       outputFrame->format,
                                                       SWS_BILINEAR,
                                                       NULL, NULL, NULL);

        ret = sws_scale(swsContext,
                        (const uint8_t * const *)rawFrame->data,
                        rawFrame->linesize,
                        0,
                        rawFrame->height,
                        outputFrame->data,
                        outputFrame->linesize);


        sws_freeContext(swsContext);
        av_frame_free(&rawFrame);

        if (ret < 0) {
            handler(NULL, THUMBNAIL_ERROR(@"Resize failed"));
            av_frame_free(&outputFrame);
            av_free(outputFrameBuffer);
            return;
        }

        // Draw to core graphics context
        CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
        CGBitmapInfo bitmapInfo = (CGBitmapInfo) kCGImageAlphaPremultipliedLast;
        CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault,
                                                     outputFrame->data[0],
                                                     outputFrame->linesize[0] * thumbHeight,
                                                     kCFAllocatorNull);
        __block CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData(data);
        __block CGImageRef image = CGImageCreate(thumbWidth, thumbHeight, 8, 32, thumbWidth * 4, rgb, bitmapInfo, dataProvider, NULL, false, kCGRenderingIntentDefault);

        QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:CGSizeMake(thumbWidth/request.scale, thumbHeight/request.scale) drawingBlock:^BOOL(CGContextRef _Nonnull context) {
            CGContextDrawImage(context, CGRectMake(0, 0, thumbWidth, thumbHeight), image);
            CGImageRelease(image);
            CGDataProviderRelease(dataProvider);
            CGColorSpaceRelease(rgb);
            av_free(outputFrameBuffer);
            av_frame_free(&outputFrame);
            return YES;
        }];

        handler(reply, nil);
    }
}

@end
