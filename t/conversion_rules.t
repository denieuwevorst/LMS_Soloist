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
my $settings = slurp('Settings.pm');
my $html = slurp('HTML/EN/plugins/SpotifySoloist/settings/basic.html');

unlike( $types, qr/^s32/m, 'registers no custom S32 LMS source type' );
unlike( $convert, qr/^\S+\s+(?:pcm|flc|mp3)\s+/m, 'registers no LMS conversion rule' );
like(
	$bridge,
	qr/-f s32le -ar 44100 -ac 2 -blocksize 4096 -i "\$SOLOIST_PCM_SHIM_FIFO".*?aresample=osf=s16:dither_method=triangular.*?-f s16le "\$FIFO_PATH"/s,
	'bridge converts and dithers S32LE to final S16LE PCM',
);
like(
	$bridge,
	qr/-analyzeduration 0 -probesize 32.*?-f s32le/s,
	'bridge bypasses ffmpeg raw-input analysis before opening the final FIFO',
);
like(
	$bridge,
	qr/aresample=osf=s16:dither_method=triangular.*?-c:a flac -sample_fmt s16 -compression_level 0.*?-f flac "\$FIFO_PATH"/s,
	'bridge emits Touch-compatible 16-bit FLAC',
);
like(
	$bridge,
	qr/-c:a libmp3lame -b:a "\$BITRATE"/,
	'bridge emits the configured fixed-bitrate MP3 stream',
);
like(
	$bridge,
	qr/ERROR: ffmpeg is required for bridge-side S32LE conversion/,
	'missing bridge converter fails explicitly',
);
like( $bridge, qr/SOLOIST_PCM_SHIM_FIFO/, 'bridge owns a separate S32LE source FIFO' );
like( $bridge, qr/encoder_supervisor/, 'bridge supervises the persistent converter' );
like(
	slurp('ProtocolHandler.pm'),
	qr/CONVERTER_CLOSE_GRACE_SECONDS\s+=>\s+0\.12/,
	'handler replacement leaves a bounded reader-free converter restart window',
);
like(
	$bridge,
	qr/SOLOIST_SHIM_ACK="\$SOLOIST_PCM_SHIM_ACK"/,
	'shim request acknowledgements remain direct and idempotent',
);
unlike( $bridge, qr/SOLOIST_SHIM_(?:FORMAT|MODE)/, 'bridge exposes no obsolete shim mode choice' );
unlike( $settings . $html, qr/playerLiveRing|liveRing\./, 'settings expose no compatibility-mode preference' );

done_testing;
