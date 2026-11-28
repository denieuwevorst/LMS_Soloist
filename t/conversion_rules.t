use strict;
use warnings;

use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	local $/;
	return <$fh>;
}

my $convert = slurp('custom-convert.conf');
my $bridge = slurp('Bin/soloist-bridge.sh');
my $pump = slurp('Bin/soloist-pcm-pump.pl');
my $plugin = slurp('Plugin.pm');
my $handler = slurp('ProtocolHandler.pm');
my $settings = slurp('Settings.pm');
my $html = slurp('HTML/EN/plugins/SpotifySoloist/settings/basic.html');

unlike( $convert, qr/^\S+\s+(?:flc|mp3)\s+/m, 'LMS has no FLAC/MP3 transcode route for Soloist' );

like( $bridge, qr/FFMPEG_BIN/, 'bridge owns compressed-format encoding' );
like( $bridge, qr/-c:a flac .*?-compression_level 0/s, 'bridge uses low-latency 16-bit FLAC encoding' );
like( $bridge, qr/-c:a libmp3lame -b:a "\$BITRATE"/, 'bridge uses the selected MP3 bitrate' );
unlike( $pump, qr/ffmpeg|FFMPEG_BIN/i, 'bounded source pump remains encoder-independent' );
like( $bridge, qr/SOLOIST_SHIM_FORMAT=s16/, 'shim output is fixed to S16LE' );
like( $bridge, qr/exec 3<> "\$FIFO_PATH"/, 'bridge keeps the final LMS FIFO open for its lifetime' );
like( $bridge, qr/\[ "\$FORMAT" != "pcm" \].*?compressed_pipeline_supervisor/s, 'only FLAC and MP3 start the persistent encoded pipeline' );
like( $bridge, qr/exec 4<> "\$PCM_SOURCE_FIFO_PATH"/, 'compressed formats keep a dedicated source FIFO open' );
like( $bridge, qr/PCM_ENCODER_FIFO_PATH/, 'compressed formats isolate the encoder behind its own FIFO' );
like( $pump, qr/SOLOIST_PCM_PUMP_BUFFER_MS.*?800/s, 'compressed source pump uses a bounded sub-second queue' );
unlike( $pump, qr/live-edge drop:/, 'source pump never discards PCM during ordinary pressure' );
like( $pump, qr/generation flush: request=/, 'source pump flushes with discontinuous generations' );
like( $bridge, qr/parec .*?--format=s16le/s, 'Pulse fallback also supplies S16LE' );
like( $bridge, qr/conversion owned by persistent bridge encoder/, 'bridge reports persistent compressed output ownership' );
like(
	$plugin,
	qr/SOLOIST_PCM_SHIM_RING_MS\}\s*=\s*200/,
	'all formats preserve the healthy 200 ms Soloist source ring',
);

like( $plugin, qr/\$format eq 'pcm' \? 'wav'/, 'PCM uses LMS native WAV delivery without a converter' );
like( $plugin, qr/\$format eq 'mp3' \? 'mp3' : 'flc'/, 'compressed formats expose their honest final LMS content types' );
like( $plugin, qr/sourceBitrateBps\s*=>\s*1_411_200/, 'source metadata publishes exact S16LE bitrate' );
like(
	$handler,
	qr/sub getStreamBitrate.*?return \$bitrate;/s,
	'handler publishes the final stream bitrate without player-cap throttling',
);
like( $plugin, qr/sourceSampleSize\s*=>\s*16/, 'source metadata publishes 16-bit samples' );
like( $plugin, qr/sourceBlockAlign\s*=>\s*4/, 'source metadata publishes stereo S16 frame alignment' );
like( $handler, qr/\$format->\{key\} eq 'pcm' \? _wavHeader\(\) : ''/, 'only direct PCM receives a WAV prefix' );
like( $handler, qr/sub isRemote \{ 1 \}/, 'LMS applies the handler-specific low player buffer threshold' );
like( $plugin, qr/input_buffer_kb\s*=>/, 'STRM milestones publish the selected player buffer threshold' );
like( $plugin, qr/INITIAL_STATE_LOOP_DELAY\s+=>\s+0\.1/, 'initial playback observation remains prompt' );
like( $plugin, qr/milestone=%s monotonic=%.3f/, 'plugin delay milestones share a monotonic timestamp format' );
like( $plugin, qr/'lms-strm-requested'/, 'plugin traces the LMS playback handoff' );
like( $plugin, qr/'player-first-status'/, 'plugin traces the first available player status' );
like( $bridge, qr/SOLOIST_SHIM_DELAY_TRACE="\$SOLOIST_DELAY_DIAGNOSTICS"/, 'bridge forwards the diagnostic switch to the shim' );
like( $settings . $html, qr/delayDiagnostics/, 'settings expose one delay diagnostic switch' );
like(
	$plugin . $settings . $html,
	qr/transitionRestartBufferMs/,
	'settings expose the global generation-only transition restart buffer',
);
like(
	$html,
	qr/name="pref_transitionRestartBufferMs".*?min="0".*?max="3000"/s,
	'transition restart buffer UI enforces the supported range',
);
unlike( $settings . $html, qr/playerLiveRing|liveRing\./, 'settings expose no obsolete compatibility mode' );

done_testing;
