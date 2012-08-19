-ifndef(epubsub_logger_included).
-define(epubsub_logger_included, ok).

-compile([{parse_transform, lager_transform}]).

-define(LOG(Level, Pattern, Args),
    lager:Level("[~p] " ++ Pattern, [?MODULE | Args])
).

-define(LOG_DEBUG(Pattern), ?LOG(debug, Pattern, [])).
-define(LOG_DEBUG(Pattern, Args), ?LOG(debug, Pattern, Args)).

-define(LOG_INFO (Pattern), ?LOG(info, Pattern, [])).
-define(LOG_INFO (Pattern, Args), ?LOG(info, Pattern, Args)).

-define(LOG_WARN (Pattern), ?LOG(warning, Pattern, [])).
-define(LOG_WARN (Pattern, Args), ?LOG(warning, Pattern, Args)).

-define(LOG_ERROR(Pattern), ?LOG(error, Pattern, [])).
-define(LOG_ERROR(Pattern, Args), ?LOG(error, Pattern, Args)).

-define(LOG_FATAL(Pattern), ?LOG(critical, Pattern, [])).
-define(LOG_FATAL(Pattern, Args), ?LOG(critical, Pattern, Args)).

-endif.