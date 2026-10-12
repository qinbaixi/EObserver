.PHONY: all web compile test release shell clean

all: release

web:
	cd web && npm ci && npm run build

compile:
	rebar3 compile

test:
	rebar3 eunit
	rebar3 ct

release: web
	rebar3 release

# Backend with live frontend: run `make shell` and `cd web && npm run dev`.
shell:
	rebar3 shell

clean:
	rebar3 clean
	rm -rf apps/eobserver/priv/www
