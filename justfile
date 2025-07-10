@default:
	just --justfile {{justfile()}} --list

@zola-dev:
  zola serve

@tailwind-dev:
  tailwindcss -i ./styles.css -o ./static/styles.css --watch=always

@dev:
  process-compose up

@build:
  tailwindcss -i ./styles.css -o ./static/styles.css
  zola build
