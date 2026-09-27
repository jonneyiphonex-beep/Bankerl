FROM erlang:27-alpine

WORKDIR /opt/bankerl

COPY src ./src
COPY priv ./priv

RUN mkdir -p ebin \
    && erlc -Werror -o ebin src/*.erl \
    && cp src/bankerl.app.src ebin/bankerl.app

EXPOSE 7474
VOLUME ["/data"]

CMD ["erl", "-noshell", "-pa", "/opt/bankerl/ebin", "-eval", "ok = application:load(bankerl), ok = application:set_env(bankerl, bind_ip, {0,0,0,0}), ok = application:set_env(bankerl, data_file, \"/data/bankerl.db\"), {ok, _} = application:ensure_all_started(bankerl), receive stop -> ok end."]