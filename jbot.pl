#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use locale;
use open qw( :utf8 :std );
use YAML::Tiny;
use Getopt::Long qw(:config bundling);
use POSIX qw( setsid );
use Fcntl qw(:seek :mode);
use Log::Handler;
use Weather::Google;
use Google::Search;
use AnyEvent;
use AnyEvent::XMPP::Client;
use AnyEvent::XMPP::Ext::Disco;
use AnyEvent::XMPP::Ext::Version;
use AnyEvent::XMPP::Ext::MUC;
use AnyEvent::XMPP::Namespaces qw/xmpp_ns/;
use AnyEvent::XMPP::Ext::Ping;

my $config = YAML::Tiny->new;
$config = YAML::Tiny->read('bot.conf');
my $login = $config->[0];
my $info = $config->[1];
my @ADMINS = @{$config->[2]->{admins}};
my $options = $config->[3];

my $JID = $login->{jid};
my $PASSWORD = $login->{pass};
my $VERSION = $info->{version};
my $ABOUT = $info->{about};
my $UNAME = $options->{uname};
my $DEFAULT_CITY = $options->{defCity};
my $WTF_FILE_NAME = $options->{wtfFile};
my $WTF_MAX_FILE_SIZE = $options->{wtfFileMaxSize};
my $ROOMS_FILE = $options->{roomsFile};
my $DEBUG = $options->{debug};
my $TLS = $options->{tls};
my $HTTP = $options->{http};
my $SCRIPT = $0;
my $HELP = "Команды:
!version [user] or !v [user] - Версия jabber клиента и os пользователя [user].
!weather [city] or !w [city] - Погода в городе [city].
!google [запрос] or !g [запрос] - Поиск в Google.
!ping [user] or !p[user] - Пинг до пользователя [user].
!wtf [ключ] - Показать фразу из wtf по ключу [ключ].
!wtfr [ключ] - Запросить у бота список всех ключ!фраза. Результат в личном сообщении.

!uptime - Аптайм сервера.
!uname - На каком сервере мы работаем?
!about - О боте.

!wtfs [ключ!фраза] - Сохранить whf фразу под ключем key.(Только для администрации)
	 				 Разделитель ключа и значения - восклицательный знак (!).
					 В ключе могут быть только символы a-zа-яA-ZА-Я0-9_
!help - Это сообщение.";

# Хеш комманд для бота из MUC
my %muc_commands = (
	"version" => \&version_comm,
	"v" => \&version_comm,
	"weather" => \&weather_comm,
	"w" => \&weather_comm,
	"google" => \&google_comm,
	"g" => \&google_comm,
	"ping" => \&ping_comm,
    "p" => \&ping_comm,
	"wtf" => \&wtf_comm,
	"wtfs" => \&wtfs_comm,
	"wtfr" => \&wtfr_comm,
	"uptime" => sub {send_message($_[0], `uptime`)},
	"uname" => sub {send_message($_[0], `$UNAME`)},
	"help" => sub {send_message($_[0], $HELP)},
	"about" => sub {send_message($_[0], $ABOUT)}
 #	"rules" или отдельно "ban" "kick" .... 
);

sub usage
{
    print <<USAGE;
$ABOUT

Использование: $SCRIPT [options]


Опции (в скобках - значения по умолчанию):
    --jid,      -j  jabber ID, например 'name\@server.org' или 'name\@server.org/resource'
    --password, -p  пароль для JID аккаунта ($PASSWORD)

    --admin,    -a  аккаунты администраторов (@ADMINS)

    --[no]debug     вкл/выкл отладку ($DEBUG)

    --help,     -h  это сообщение


Пример:

$SCRIPT -j soso\@server.ru/home -w qwerty --admin admin\@server.org

USAGE

    exit (0);
}

GetOptions(
    'password|passwd|p=s' => \$PASSWORD,
    'admin|a=s'      => \@ADMINS,
    'debug|d!'       => \$DEBUG,
    'jid|jabber|j=s' => \$JID,
    'help|h'         => sub {usage}
);

unless ($JID)
{
    usage();
}

open(STDIN, ">/dev/null") or die "Не могу открыть STDIN: $!\n";
open(STDOUT, ">/dev/null") or die "Не могу открыть STDOUT: $!\n";
open(STDERR, ">/dev/null") or die "Не могу открыть STDIN: $!\n";

my $j       = AnyEvent->condvar;
my $cl      = AnyEvent::XMPP::Client->new (debug => $DEBUG);
my $disco   = AnyEvent::XMPP::Ext::Disco->new;
my $version = AnyEvent::XMPP::Ext::Version->new;
my $ping 	= AnyEvent::XMPP::Ext::Ping->new;

my $log = Log::Handler->new();
$log->add(
	file => {
		filename => "jbot.log",
		maxlevel => "debug",
		minlevel => "emerg",
		timeformat => "%H:%M:%S",
		message_layout => "%D %T %L %m",
		newline => 1,
#		utf8 => 1,
	}
);
$log->info($ABOUT);

$cl->add_extension ($disco);
$cl->add_extension ($version);
$cl->add_extension ($ping);

$cl->add_account ($JID, $PASSWORD);
$log->info("Connecting to $JID...");

# Заполнение хеша комнат, в которые нужно зайти боту.
my @rooms = ();
open(ROOMS_FILE, "<", $ROOMS_FILE) or $log->notice("Can't open file $ROOMS_FILE : $!");
while(<ROOMS_FILE>) {
	$cl->add_extension(my $disco = AnyEvent::XMPP::Ext::Disco->new());
	push @rooms, AnyEvent::XMPP::Ext::MUC->new(disco => $disco);
	$cl->add_extension($rooms[$#rooms]);
	$rooms[$#rooms]->reg_cb(
		message => \&muc_incoming_message,
		error => sub {
			my ($muc, $room, $error) = @_;
			$log->error("MUC ERROR " . $room->jid . " : " . $error->string);
		},
		join_error => sub {
			my ($muc, $room, $error) = @_;
			$log->error("Enter to the room " . $room->jid . " failed! : " . $error->string);
		},
		enter => sub {
			my ($muc, $room, $user) = @_;
			$log->info("Enter to the room " . $room->jid . " success!");
		}
	);
}
seek(ROOMS_FILE, 0, 0);

# Обработка событий для сообщений НЕ из комнаты.
$cl->reg_cb (
   session_ready => sub {
      my ($cl, $acc) = @_;
      $log->info("Connected!");
	  my $i = 0;
	  # Вход в комнаты.
	  while(my $current_room = <ROOMS_FILE>) {
		  my ($room_jid, $room_nick, $room_password) = split ':', $current_room;
		  my %args = (
			  history => {chars => 0},
			  password => $room_password,
			  nickcollision_cb => sub {return "$room_nick-tmp"}
		  );
		  $rooms[$i]->join_room($acc->connection, $room_jid, $room_nick, %args);
		  $i++;
	  }
	  close(ROOMS_FILE) or $log->error("Can't close file $ROOMS_FILE : $!");
   },
   error => sub {
      my ($cl, $acc, $error) = @_;
      $log->error('Error encountered: ' . $error->string);
      $j->broadcast;
   },
   disconnect => sub {
      $log->error("Got disconnected: [@_]\n");
      $j->broadcast;
   },
   message => sub {
      my ($cl, $acc, $msg) = @_;
      return unless $msg;
      my $cmd = $msg->any_body;
      my $adm = $msg->from;
	  $adm =~ s/\/.*//;
	  my $is_adm = '';

      $log->info("# $adm -> $cmd:");

      my $repl = $msg->make_reply;

	  foreach (@ADMINS) {
		  $is_adm = 1 if $_ eq $adm;
	  }

      if($is_adm) {
          my $out = '';
          if ($cmd =~ s/^\s*cd\s+//)
          {
             $out = chdir($cmd) ? `pwd` : 'Failed'
          } else
          {
              $out = `$cmd 2>&1`
          }
          if ($out)
          {
            $log->info($out);
            $repl->add_body($out);
          }
      } else {
          $log->emerg("Forbidden.\n");
          $repl->add_body('Forbidden');
      }

      $repl->send;
   }
);

my $p = fork();
if($p == 0) {
	setsid();
	$cl->start;
	$j->wait;
} elsif($p > 0) {
	exit(0);
} else {
	$log->error("Can't fork: $!\n");
	exit(1);
}

exit(0);

sub muc_incoming_message {
	my ($muc, $room, $msg, $is_echo) = @_;
	if($msg->body =~ m{^\s*[!.]\s*(\w+)\s*(.+)*}) {
		if(exists $muc_commands{$1}) {
			&{$muc_commands{$1}}($msg, $2);
		}
	}
}

sub send_message {
	my ($msg, $result, $msgtype) = @_;
	my ($from_nick) = $msg->from =~ m{/(.+)};
	my $answer = new AnyEvent::XMPP::Ext::MUC::Message->new(
		body => "$from_nick: $result"
	);
	$msg->make_reply($answer);
	if($msgtype) {
		$answer->type($msgtype);
		$answer->to($answer->to . "/$from_nick");
	}
	$answer->send;
}

sub isAdmin {
	my ($user) = @_;
	return 0 unless($user);
	return 1 if $user->role =~ /moderator|admin|owner/;
}

# Функция version_comm: Определяет версию jabber клиента и операционную систему пользователя.
# Переменная $nick: JID, операционную систему и jabber клиент которого нужно получить.
# Возвращаемое значение: клиент версия OS пользователя.
sub version_comm {
	my ($msg, $nick) = @_;
    $nick =~ s/\s$//i;
	unless($nick) {
		$nick = $msg->from;
	} else {
		$nick = $msg->room->get_user($nick);
		unless(defined $nick) {
			send_message($msg, "Нет такого пользователя.");
			return;
		}
		$nick = $nick->in_room_jid;
	}

	my $version_obj = AnyEvent::XMPP::Ext::Version->new;
  	$version_obj->request_version($msg->room->connection, $nick,
		sub {
			my ($result, $error) = @_;
			if($error) {
				send_message($msg, "Не могу получить данные пользователя:" . $error->condition);
				return;
			}
			send_message($msg, $result->{'name'} . " " . $result->{'version'} . " " . $result->{'os'});
		}
	);
}

# Функция ping_comm: пингует хост по JID пользователя.
# Переменная $nick: JID, который нужно пинговать.
# Возвращаемое значение: значение ping до JID в ms. 
sub ping_comm {
	my ($msg, $nick) = @_;
	unless($nick) {
		$nick = $msg->from;
	} else {
		$nick = $msg->room->get_user($nick);
		unless(defined $nick) {
			send_message($msg, "Нет такого пользователя");
			return;
		}
		$nick = $nick->in_room_jid;
	}
	my $ping = AnyEvent::XMPP::Ext::Ping->new;
	$ping->ping($msg->room->connection, $nick,
		sub {
			# Странный глюк. $error всегда defined.
			my ($result, $error) = @_;
			$result = sprintf("пинг до $nick %.2fmc", $result);
			send_message($msg, $result);
		}
	);
}

# Функция weather_comm: выполняет запрос прогноза погоды у Google.
# Переменная $city: содержит название города для запроса.
# Возвращаемое значение: погода на текущий момент и максимальная температура на завтра.
sub weather_comm {
	my ($msg, $city) = @_;
	$city = $DEFAULT_CITY unless $city;
    my $w = new Weather::Google( $city, {language => 'ru'} );
	unless(@{$w->{'forecast'}}) {
		send_message($msg, "Нет такого города");
		return;
	}
    my @wc = $w->current qw( temp_c humidity condition );
    my @wt = $w->tomorrow qw(high condition);
    my $weather = "Сейчас в $city за окном:\n" .
    "Температура: $wc[0] °C\n$wc[1]\n$wc[2]\n\nЗавтра:\nТемпература: $wt[0] °C\n$wt[1]";
	send_message($msg, $weather);
}

# Функция gsearch_comm: выполняет поиск в Google.
# Переменная $query: пользовательский поисковый запрос.
# Возвращаемое значение: 3 первых результата поиска со ссылками на ресурсы.
sub google_comm {
    my ($msg, $query) = @_;
    my $res;
    unless($query) {
        send_message($msg, "Не задано ключевое слово для поиска");
        return;
    }
    my $search = Google::Search->Web( query => $query );
	unless($search->next) {
		send_message($msg, "Не найдено результатов");
		return;
	}
    for (my $i=1; $i<=3; $i++) {
        my $result = $search->next;
		my $rr = $result->titleNoFormatting;
		utf8::decode($rr);
        $res .= $i . ". " . $rr . "\n" . $result->uri . "\n";
    }
	send_message($msg, $res);
}

# Функиця wtf_comm: выводит запомненное сообщение по ключу.
# Переменная $key: ключ фразы, которую нужно найти в файле.
# Возвращаемое значение: фраза по ключу $key.
sub wtf_comm {
	my ($msg, $key) = @_;
	unless($key) {
		send_message($msg, "Не задан ключ!");
		return;
	}
	unless(open(WTF_FILE, "<", $WTF_FILE_NAME)) {
		send_message($msg, "Невозможно открыть файл $WTF_FILE_NAME для записи: $!");
		return;
	}
	my ($from_room) = $msg->from =~ m{(.+)\/.*};
	while(my $str = <WTF_FILE>) {
			next unless $str =~ /$from_room/;
			if($str =~ /$from_room!$key!(.+)/) {
				send_message($msg, $1);
				return;
			}
	}
	unless(close(WTF_FILE)) {
		send_message($msg, "Не могу закрыть файл $WTF_FILE_NAME. Обратитесь к администраторам бота: @ADMINS");
		return;
	}
	send_message($msg, "Нет такого ключа.");
}

# Функиця wtfs_comm: сохраняет wtf фразу в базе фраз.
# Переменная $phrase: [ключ:фраза].
# Возвращаемое значение: сообщение об успешном сохранении фразы или об ошибке.
sub wtfs_comm {
	my ($msg, $phrase) = @_;
	unless(isAdmin($msg->room->get_user_jid($msg->from))) {
		send_message($msg, "Сохранять WTF можно только администрации!");
		return;
	}
	unless($phrase) {
		send_message($msg, "Не задан ключ:фраза для сохранения");
		return;
	}
	my ($key, $value) = $phrase =~ m{(.+?)\s*!\s*(.+)};
	unless($key || $value) {
		send_message($msg, "Не заданы ключ или фраза");
		return;
	}
	if($key =~ /\W/) {
		send_message($msg, "Присутствуют запрещенные символы в ключе. Смотри !help");
		return;
	}
	unless(open(WTF_FILE, "+>>", $WTF_FILE_NAME)) {
		send_message($msg, "Невозможно открыть файл $WTF_FILE_NAME для записи: $!");
		return;
	}
	seek(WTF_FILE, 0, SEEK_SET);
	if(-s WTF_FILE >= ($WTF_MAX_FILE_SIZE * 1024)) {
		send_message($msg, "Не хватает места для записи в базу. Обратитесь к администрторам бота: @ADMINS");
		return;
	}
	my ($from_room) = $msg->from =~ m{(.+)\/.*};
	while(my $str = <WTF_FILE>) {
			next unless $str =~ /$from_room/;
			if($str =~ /$from_room!$key!.+/) {
				send_message($msg, "Ключ \"$key\" уже существует в базе.");
				return;
			}
	}
	seek(WTF_FILE, 0, SEEK_END);
	print WTF_FILE "$from_room!$key!$value\n";
	unless(close(WTF_FILE)) {
		send_message($msg, "Не могу закрыть файл $WTF_FILE_NAME. Обратитесь к администраторам бота: @ADMINS");
		return;
	}
	send_message($msg, "Фраза \"$value\" с ключем \"$key\" успешно добавлены в базу.");
}

# Функиця wtfr_comm: отправляет запросившему пользователю личное сообщение со всеми парами [ключ!фраза]
# 					 или пару [ключ!фраза] если определен параметр $key.
# Переменная $key: ключ, который нужно найти.
# Возвращаемое значение: личное сообщение, содержащее данные из базы фраз.
sub wtfr_comm  {
	my ($msg, $key) = @_;
	$key = '.+?' unless($key);
	unless(open(WTF_FILE, "<", $WTF_FILE_NAME)) {
		send_message($msg, "Невозможно открыть файл $WTF_FILE_NAME для записи: $!");
		return;
	}
	my ($from_room) = $msg->from =~ m{(.+)\/.*};
	my $value = "";
	while(my $str = <WTF_FILE>) {
			next unless $str =~ /$from_room/;
			$value .= "$1 - $2\n" if($str =~ /$from_room!($key)!(.+)/);
	}
	unless(close(WTF_FILE)) {
		send_message($msg, "Не могу закрыть файл $WTF_FILE_NAME. Обратитесь к администраторам бота: @ADMINS");
		return;
	}
	send_message($msg, $value, 'chat');
}
