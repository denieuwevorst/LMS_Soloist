#!/usr/bin/env perl

use strict;
use warnings;

use Errno qw(EAGAIN EWOULDBLOCK EINTR EPIPE);
use Fcntl qw(O_NONBLOCK O_RDONLY O_WRONLY);
use Time::HiRes qw(time sleep);
use constant F_SETPIPE_SZ => 1031;

my $sourcePath = $ENV{SOLOIST_PCM_PUMP_SOURCE}
	or die "SOLOIST_PCM_PUMP_SOURCE is required\n";
my $outputPath = $ENV{SOLOIST_PCM_PUMP_OUTPUT}
	or die "SOLOIST_PCM_PUMP_OUTPUT is required\n";
my $finalOutputPath = $ENV{SOLOIST_PCM_PUMP_FINAL_OUTPUT} || '';
my $controlPath = $ENV{SOLOIST_PCM_PUMP_CONTROL} || '';
my $shimAckPath = $ENV{SOLOIST_PCM_PUMP_SHIM_ACK} || '';
my $pumpAckPath = $ENV{SOLOIST_PCM_PUMP_ACK} || '';
my $bufferMs = $ENV{SOLOIST_PCM_PUMP_BUFFER_MS} || 800;
my $restartEncoder = $ENV{SOLOIST_PCM_PUMP_RESTART_ENCODER} ? 1 : 0;
my $encoderFresh = $ENV{SOLOIST_PCM_PUMP_ENCODER_FRESH} ? 1 : 0;
my $fatalOutput = $ENV{SOLOIST_PCM_PUMP_FATAL_OUTPUT} ? 1 : 0;
my $frameBytes = 4;
my $bytesPerSecond = 44_100 * $frameBytes;
my $maxQueuedBytes = int( $bytesPerSecond * $bufferMs / 1000 );
$maxQueuedBytes -= $maxQueuedBytes % $frameBytes;

my $stopping = 0;
$SIG{TERM} = sub { $stopping = 1 };
$SIG{INT} = sub { $stopping = 1 };
$SIG{PIPE} = 'IGNORE';

sub _openFifo {
	my ( $path, $flags, $label ) = @_;
	while ( !$stopping ) {
		my $fh;
		if ( sysopen( $fh, $path, $flags | O_NONBLOCK ) ) {
			binmode($fh);
			return $fh;
		}
		warn "[soloist-pump] can't open $label FIFO '$path': $!; retrying\n";
		sleep 0.1;
	}
	return;
}

sub _requestIdFromFile {
	my ($path) = @_;
	return unless $path && open( my $fh, '<', $path );
	my $line = <$fh>;
	close $fh;
	return unless defined $line && $line =~ /\A\s*(\d+)/;
	return 0 + $1;
}

sub _drainFifo {
	my ($path) = @_;
	my $fh;
	return 0 unless sysopen( $fh, $path, O_RDONLY | O_NONBLOCK );
	binmode($fh);
	my $discarded = 0;
	while (1) {
		my $chunk = '';
		my $read = sysread( $fh, $chunk, 65_536 );
		if ( defined $read ) {
			last unless $read;
			$discarded += $read;
			next;
		}
		next if $! == EINTR;
		last if $! == EAGAIN || $! == EWOULDBLOCK;
		last;
	}
	close $fh;
	return $discarded;
}

sub _publishAck {
	my ($requestId) = @_;
	return 1 unless $pumpAckPath;
	my $tmp = "$pumpAckPath.tmp.$$";
	open( my $fh, '>', $tmp ) or return;
	my $ok = print {$fh} "$requestId 0 pump\n";
	$ok = close($fh) && $ok;
	return unless $ok;
	return rename( $tmp, $pumpAckPath );
}

my $source = _openFifo( $sourcePath, O_RDONLY, 'source' ) or exit 0;
my $output = _openFifo( $outputPath, O_WRONLY, 'output' ) or exit 0;
fcntl( $output, F_SETPIPE_SZ, 16_384 );
my $queue = '';
my $pendingRequest;
my $lastAckedRequest = _requestIdFromFile($pumpAckPath) || 0;
my $holdOutputUntil = 0;
my $nextControlCheck = 0;
my $nextSummary = time() + 5;
my $readBytes = 0;
my $writtenBytes = 0;
my $maxQueued = 0;
my $pressureSince;

print STDERR
	"[soloist-pump] started source=$sourcePath output=$outputPath "
	. "buffer=${bufferMs}ms max_queue=$maxQueuedBytes bytes\n";

while ( !$stopping ) {
	my $now = time();
	my $worked = 0;

	if ( $now >= $nextControlCheck ) {
		$nextControlCheck = $now + 0.01;
		my $requestId = _requestIdFromFile($controlPath);
		if ( defined $requestId && $requestId > $lastAckedRequest ) {
			$pendingRequest = $requestId;
			$holdOutputUntil = $now + 3600;
		}
		elsif (
			defined $requestId
			&& $requestId == $lastAckedRequest
			&& $pumpAckPath
			&& !-f $pumpAckPath
		) {
			_publishAck($requestId);
		}

		if (
			defined $pendingRequest
			&& ( _requestIdFromFile($shimAckPath) || 0 ) == $pendingRequest
		) {
			my $queued = length($queue);
			$queue = '';
			my $sourceDiscarded = _drainFifo($sourcePath);
			my $outputDiscarded = _drainFifo($outputPath);
			my $finalDiscarded =
				$finalOutputPath ? _drainFifo($finalOutputPath) : 0;
			if ( $restartEncoder && !$encoderFresh ) {
				print STDERR
					"[soloist-pump] generation restart: request=$pendingRequest "
					. "queued=$queued source=$sourceDiscarded "
					. "encoder_input=$outputDiscarded final=$finalDiscarded bytes\n";
				close $source;
				close $output;
				exit 75;
			}
			$lastAckedRequest = $pendingRequest;
			_publishAck($lastAckedRequest);
			$encoderFresh = 0;
			$holdOutputUntil = $now + 0.15;
			print STDERR
				"[soloist-pump] generation flush: request=$lastAckedRequest "
				. "queued=$queued source=$sourceDiscarded "
				. "output=$outputDiscarded final=$finalDiscarded bytes\n";
			undef $pendingRequest;
			$worked = 1;
		}
	}

	for ( 1 .. 16 ) {
		last if length($queue) >= $maxQueuedBytes;
		my $chunk = '';
		my $available = $maxQueuedBytes - length($queue);
		my $read = sysread(
			$source,
			$chunk,
			$available < 16_384 ? $available : 16_384,
		);
		if ( defined $read ) {
			last unless $read;
			$queue .= $chunk;
			$readBytes += $read;
			$worked = 1;
			next;
		}
		next if $! == EINTR;
		last if $! == EAGAIN || $! == EWOULDBLOCK;
		warn "[soloist-pump] source read failed: $!; reopening\n";
		close $source;
		$source = _openFifo( $sourcePath, O_RDONLY, 'source' ) or last;
		last;
	}

	if ( length($queue) >= $maxQueuedBytes ) {
		$pressureSince = $now unless defined $pressureSince;
	}
	elsif ( defined $pressureSince ) {
		printf STDERR
			"[soloist-pump] queue pressure cleared after %.1f ms without dropping PCM\n",
			1000 * ( $now - $pressureSince );
		undef $pressureSince;
	}
	$maxQueued = length($queue) if length($queue) > $maxQueued;

	if ( length($queue) && !defined($pendingRequest) && $now >= $holdOutputUntil ) {
		for ( 1 .. 16 ) {
			last unless length($queue);
			my $length = length($queue) > 65_536 ? 65_536 : length($queue);
			my $written = syswrite( $output, $queue, $length );
			if ( defined $written ) {
				last unless $written;
				substr( $queue, 0, $written, '' );
				$writtenBytes += $written;
				$worked = 1;
				next;
			}
			next if $! == EINTR;
			last if $! == EAGAIN || $! == EWOULDBLOCK;
			if ( $! != EPIPE ) {
				warn "[soloist-pump] output write failed: $!; reopening\n";
			}
			if ($fatalOutput) {
				warn "[soloist-pump] encoder input failed: $!; pipeline restart required\n";
				close $source;
				close $output;
				exit 74;
			}
			close $output;
			$output = _openFifo( $outputPath, O_WRONLY, 'output' ) or last;
			fcntl( $output, F_SETPIPE_SZ, 16_384 ) if $output;
			last;
		}
	}

	if ( $now >= $nextSummary ) {
		printf STDERR
			"[soloist-pump] runtime summary: read=%d written=%d queued=%.1f ms "
			. "max_queued=%.1f ms drops=0.0 ms pending=%s\n",
			$readBytes,
			$writtenBytes,
			1000 * length($queue) / $bytesPerSecond,
			1000 * $maxQueued / $bytesPerSecond,
			defined $pendingRequest ? $pendingRequest : 'none';
		$readBytes = $writtenBytes = $maxQueued = 0;
		$nextSummary = $now + 5;
	}

	sleep 0.005 unless $worked;
}

close $source;
close $output;
print STDERR "[soloist-pump] stopped\n";
