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

like( $types, qr/^s32p\s+-\s+audio\/x-soloist-s32-pcm\s+audio$/m, 'registers the S32-to-PCM source type' );
like( $types, qr/^s32f\s+-\s+audio\/x-soloist-s32-flac\s+audio$/m, 'registers the S32-to-FLAC source type' );
like(
	$convert,
	qr/^s32p\s+pcm\s+\*\s+\*.*?aresample=osf=s16:dither_method=triangular.*?-f s16le -/ms,
	'PCM rule converts and dithers S32LE to S16LE instead of passing 32-bit audio to the player',
);
like(
	$convert,
	qr/^s32p\s+pcm\s+\*\s+\*.*?-flush_packets 1 -f s16le -/ms,
	'PCM rule flushes converted samples promptly for realtime player delivery',
);
unlike(
	$convert,
	qr/^s32p\s+pcm\s+\*\s+\*.*?-f s32le -/ms,
	'PCM rule cannot pass raw S32LE to the player',
);
like(
	$convert,
	qr/^s32f\s+flc\s+\*\s+\*.*?aresample=osf=s16:dither_method=triangular.*?-sample_fmt s16/ms,
	'FLAC rule bounds the encoded stream to Touch-compatible 16-bit samples',
);
for my $rate (qw(96 128 160 192 256 320)) {
	like( $types, qr/^s32m\Q$rate\E\s+-\s+audio\/x-soloist-s32-mp3-\Q$rate\E\s+audio$/m, "registers the ${rate}k S32-to-MP3 source type" );
	like( $convert, qr/^s32m\Q$rate\E\s+mp3\s+\*\s+\*.*?^\s*\[ffmpeg\].*?-b:a \Q$rate\Ek /ms, "hard-codes the selected ${rate}k MP3 bitrate" );
}

for my $rule (qw(s32p-pcm s32f-flc)) {
	my ($source, $dest) = split /-/, $rule;
	like( $convert, qr/^\Q$source\E\s+\Q$dest\E\s+\*\s+\*$/m, "defines $source to $dest conversion" );
}
is( () = $convert =~ /\[ffmpeg\]/g, 8, 'all final formats use LMS dependency-checked ffmpeg rules' );
my @commands = $convert =~ /^\s*\[ffmpeg\](.*)$/mg;
for my $command (@commands) {
	like(
		$command,
		qr/-blocksize 4096 -i \$FILE\$/,
		'conversion command bounds streaming WAV input reads for realtime cadence',
	);
}
unlike( $bridge, qr/ffmpeg/i, 'bridge never invokes or configures ffmpeg' );
unlike( $bridge, qr/SOLOIST_SHIM_(?:FORMAT|MODE)|SOLOIST_PCM_SHIM_FIFO/, 'bridge exposes no obsolete shim mode or intermediate FIFO' );
unlike( $settings . $html, qr/playerLiveRing|liveRing\./, 'settings expose no compatibility-mode preference' );

done_testing;
