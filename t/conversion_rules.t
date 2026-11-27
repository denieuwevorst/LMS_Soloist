use strict;
use warnings;

use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	local $/;
	return <$fh>;
}

my $types = slurp('custom-types.conf');
my $convert = slurp('custom-convert.conf');
my $bridge = slurp('Bin/soloist-bridge.sh');
my $plugin = slurp('Plugin.pm');
my $handler = slurp('ProtocolHandler.pm');
my $settings = slurp('Settings.pm');
my $html = slurp('HTML/EN/plugins/SpotifySoloist/settings/basic.html');

like( $types, qr/^s16f\s+-\s+audio\/x-soloist-s16-flac\s+audio$/m, 'registers the S16-to-FLAC source type' );
for my $rate (qw(96 128 160 192 256 320)) {
	like( $types, qr/^s16m\Q$rate\E\s+-\s+audio\/x-soloist-s16-mp3-\Q$rate\E\s+audio$/m, "registers the ${rate}k S16-to-MP3 source type" );
	like( $convert, qr/^s16m\Q$rate\E\s+mp3\s+\*\s+\*.*?^\s*\[ffmpeg\].*?-b:a \Q$rate\Ek /ms, "LMS owns the selected ${rate}k MP3 conversion" );
}
like(
	$convert,
	qr/^s16f\s+flc\s+\*\s+\*.*?^\s*\[ffmpeg\].*?-c:a flac .*?-sample_fmt s16/ms,
	'LMS owns Touch-compatible 16-bit FLAC conversion',
);
is( () = $convert =~ /\[ffmpeg\]/g, 7, 'only LMS FLAC/MP3 rules invoke ffmpeg' );

unlike( $bridge, qr/ffmpeg|FFMPEG_BIN|SOLOIST_PCM_SHIM_FIFO/i, 'bridge has no ffmpeg process or intermediate encoder FIFO' );
like( $bridge, qr/SOLOIST_SHIM_FORMAT=s16/, 'shim output is fixed to S16LE' );
like( $bridge, qr/exec 3<> "\$FIFO_PATH"/, 'bridge keeps one final FIFO open for its lifetime' );
like( $bridge, qr/parec .*?--format=s16le/s, 'Pulse fallback also supplies S16LE' );
like( $bridge, qr/conversion owned by LMS/, 'bridge reports LMS-owned output conversion' );

like( $plugin, qr/\$format eq 'pcm' \? 'wav'/, 'PCM uses LMS native WAV delivery without a converter' );
like( $plugin, qr/'s16m' \. int\( \$bitrateBps \/ 1000 \)/, 'MP3 preference selects a bitrate-specific LMS source type' );
like( $plugin, qr/contentType.*?'s16m'.*?:\s*'s16f'/s, 'FLAC preference selects the LMS FLAC source type' );
like( $plugin, qr/sourceBitrateBps\s*=>\s*1_411_200/, 'source metadata publishes exact S16LE bitrate' );
like( $plugin, qr/sourceSampleSize\s*=>\s*16/, 'source metadata publishes 16-bit samples' );
like( $plugin, qr/sourceBlockAlign\s*=>\s*4/, 'source metadata publishes stereo S16 frame alignment' );
like( $handler, qr/\$\{\*\$self\}\{prefix\}\s*=\s*_wavHeader\(\)/, 'every LMS source generation starts with a truthful S16 WAV header' );
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
