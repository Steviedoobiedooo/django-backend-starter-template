# Django Framework Starter Template

## Author
* [Steve Miayo] (https://github.com/Steviedoobiedooo)

This is a Starter Template with Docker setup for a Django Project.

## Requirements

* Internet connection
* [Docker] (https://www.docker.com/products/docker-desktop/)
* [Python] (https://www.python.org/downloads/)
* [pip] (https://pip.pypa.io/en/stable/cli/pip_download/)
* [Django] (https://www.djangoproject.com/download/)

## Setup

1. Make sure Docker Desktop is running.
2. Navigate to the project directory.
3. Run the following command to set up the project: bash setup.sh project_name app_name
    * Ex. bash setup.sh sample_project app
4. This will start the project and run the app in localhost port 8080 and other related services.

## Services
* Django Web Server (app)
* PostgreSQL (postgres)
* NGINX (nginx)
* Redis (redis)
* Celery Worker (worker)
* Celery Beat Scheduler (celerybeat)
* Celery Flower (flower)


## Pages
* Django Admin (http://localhost/admin/)
* Swagger API Documentation (http://localhost/api/docs/)
* Redoc API Documentation (http://localhost/api/redoc/)
* Flower Admin Interface (http://localhost:5555)
