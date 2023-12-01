FROM ruby:3.2.2-alpine3.18

# install libraries
RUN apk add --update build-base libxml2-dev libffi-dev

# copy gems
COPY install /install
RUN cd /install && sh bootstrap.sh

COPY filesystem /filesystem

WORKDIR /filesystem
CMD ["/bin/sh"]
