#!/bin/sh
cd `dirname $0`
exec erl -pa ebin deps/*/ebin -boot start_sasl -config priv/app.config -s epubsub_client
