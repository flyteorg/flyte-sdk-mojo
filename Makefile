.PHONY: hello agent remote remote-mojo remote-build remote-fail test clean

hello:
	mojo run hello.mojo

agent:
	mojo run agent.mojo

remote:
	mojo run remote_hello.mojo

remote-build:
	@echo "Building linux/amd64 Mojo task binaries (docker)..."
	docker run --rm --platform linux/amd64 \
		-v "$$(pwd)/mojo_tasks":/src -w /src \
		python:3.12-slim \
		bash -lc "apt-get update -qq >/dev/null && apt-get install -y -qq gcc >/dev/null 2>&1; \
			pip install --quiet mojo==1.0.0 && \
			/usr/local/bin/mojo build -O3 -o hello_binary hello_task.mojo && \
			/usr/local/bin/mojo build -O3 -o fib_binary fib_task.mojo && \
			cp /usr/local/lib/python3.12/site-packages/modular/lib/libKGENCompilerRTShared.so \
			   /usr/local/lib/python3.12/site-packages/modular/lib/libMSupportGlobals.so \
			   /usr/local/lib/python3.12/site-packages/modular/lib/libAsyncRTRuntimeGlobals.so \
			   /src/ && \
			rm -f /src/libMojoLLDB.so /src/liblldb*.so /src/libMojoJupyter.so /src/mojo-repl-entry-point && \
			ls -la /src"
	@echo "Done. Binaries in mojo_tasks/."

remote-mojo:
	mojo run remote_mojo_task.mojo

remote-fail:
	mojo run remote_fail_test.mojo

test:
	mojo run tests/local_test.mojo

clean:
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
