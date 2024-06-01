#!/bin/bash

# Exit on error
set -e

# Check if project name, and app name are provided
if [ $# -ne 2 ]; then
  echo "Usage: $0 <project_name> <app_name>"
  exit 1
fi

PROJECT_NAME=$1
APP_NAME=$2

# Check for required commands
command -v python >/dev/null 2>&1 || { echo >&2 "Python is required but it's not installed. Aborting."; exit 1; }
command -v pip >/dev/null 2>&1 || { echo >&2 "pip is required but it's not installed. Aborting."; exit 1; }
command -v django-admin >/dev/null 2>&1 || { echo >&2 "Django is required but it's not installed. Installing..."; pip install django; }

# Ensure Docker is running
if ! docker ps > /dev/null 2>&1; then
    echo "Docker Desktop is not running. Please start Docker Desktop and try again."
    exit 1
else
    echo "Docker Desktop is running."
fi

echo "Creating Django project..."
django-admin startproject $PROJECT_NAME
cd $PROJECT_NAME

echo Creating .gitignore file
cat << EOL > .gitignore
# Byte-compiled / optimized / DLL files
__pycache__/
*.py[cod]
*$py.class

# Distribution / packaging
.Python
env/
venv/
ENV/
env.bak/
venv.bak/
*.egg-info/
dist/
build/
.eggs/

# Installer logs
pip-log.txt
pip-delete-this-directory.txt

# Unit test / coverage reports
htmlcov/
.tox/
.nox/
.coverage
.coverage.*
.cache
nosetests.xml
coverage.xml
*.cover
*.py,cover
.hypothesis/

# Translations
*.mo
*.pot

# Django stuff
*.log
*.pot
*.pyc
*.pyo
__pycache__/
local_settings.py
db.sqlite3

# If using django-compressor
COMPRESSOR_OUTPUT_DIR

# Static and media files
staticfiles/
media/

# Flask stuff
instance/
.webassets-cache

# Scrapy stuff
.scrapy

# Sphinx documentation
docs/_build/

# PyBuilder
target/

# Jupyter Notebook
.ipynb_checkpoints

# PyCharm
.idea/
*.iml
*.ipr
*.iws

# VS Code
.vscode/

# macOS
.DS_Store

# Windows
Thumbs.db
ehthumbs.db
*.stackdump
.DS_Store?
._*
.Spotlight-V100
.Trashes
desktop.ini
$RECYCLE.BIN/

# Logs
logs/
*.log

# Editor / IDE
.vscode/
.idea/
*.sublime-project
*.sublime-workspace

# Virtual environment
venv/
ENV/
env/
env.bak/
venv.bak/
__pycache__/
*.py[cod]
*.pyo
*.pyc
*.pyd
.Python
__pypackages__/

# Jupyter Notebook
.ipynb_checkpoints/

# C extensions
*.so

# mypy
.mypy_cache/
.dmypy.json
dmypy.json

# Pyre type checker
.pyre/

# Celery beat schedule file
celerybeat-schedule

# Sentry files
.sentrycli

# Docker
*.env
.dockerignore
Dockerfile
docker-compose.yml

# Other
*.swp
*.swo
*.swn

# Pytest
.cache/
*.cover
*.py,cover
.pytest_cache/

# Coverage
.coverage
.coverage.*
.cache
nosetests.xml
coverage.xml
*.cover
*.py,cover

# PEP8
.pep8

# Jython
.cachedir/

# Pyright
pyrightconfig.json

# Profiles for profiling tools
.prof

# Django migration files
*.pyc

# Django production settings
.production

# Django static files
static/
staticfiles/

# Ansible
*.retry

# PyInstaller
*.spec

# Distribution / packaging
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/

# PyBuilder
.pybuilder/
target/

# pyenv
.python-version

# Poetry
poetry.lock

# PDM
__pypackages__/

# celery beat schedule file
celerybeat-schedule
celerybeat.pid

# SageMath parsed files
*.sage.py

# dotenv
.env
.venv
env/
venv/
ENV/
env.bak/
venv.bak/
.envrc
*.env
*.env.*

# Spyder project settings
.spyderproject
.spyproject

# Rope project settings
.ropeproject

# Pyre type checker
.pyre/

# Django migration files
*.pyc

# Django production settings
.production

# Django static files
static/
staticfiles/

# PyInstaller
*.spec

EOL

echo "Creating Django app..."
python manage.py startapp $APP_NAME

echo "Creating and configuring NGINX"
mkdir -p gateway

cat << 'EOL' > gateway/nginx.conf
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
upstream app {
  server app:8080;
}

server {
    listen 80 default_server;

    client_max_body_size 10M;

    location ~ /(api|admin|docs) {
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header Host $http_host;
      proxy_pass http://app;
      proxy_redirect off;
    }

}
EOL

cat <<EOL > docker-compose.yml
services:
  redis:
    restart: always
    image: redis:latest
    volumes:
      - redis_data:/data
    networks:
      - $PROJECT_NAME-network

  postgres:
    restart: always
    image: postgres:latest
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: root
      POSTGRES_PASSWORD: root
      POSTGRES_DB: $PROJECT_NAME
    ports:
      - "5432:5432"
    networks:
      - $PROJECT_NAME-network

  nginx:
    restart: always
    image: nginx:latest
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    links:
      - app:app
    ports:
      - "80:80"
      - "443:443"
    networks:
      - $PROJECT_NAME-network

  app:
    &app
    build: .
    restart: always
    volumes:
      - .:/code
    working_dir: /code
    ports:
      - "8080:8080"
    depends_on:
      - postgres
      - redis
    links:
      - postgres:postgres
      - redis:redis
    env_file:
      - .env.dev
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"
    command: >
      sh -c "python manage.py collectstatic --noinput &&
             python manage.py makemigrations &&
             python manage.py migrate &&
             python manage.py runserver 0.0.0.0:8080"

  worker:
    build: .
    command: celery -A $PROJECT_NAME worker --loglevel=info -c 4
    volumes:
      - .:/code
    depends_on:
      - postgres
      - redis
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  celerybeat:
    build: .
    restart: always
    command: celery -A $PROJECT_NAME beat -l info
    volumes:
      - .:/code
    depends_on:
      - postgres
      - redis
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  flower:
    build: .
    command: celery -A $PROJECT_NAME flower --port=5555
    ports:
      - "5555:5555"
    depends_on:
      - worker
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

networks:
  $PROJECT_NAME-network:

volumes:
  redis_data:
  postgres_data:

EOL

cat <<EOL > development.yml
services:
  redis:
    restart: always
    image: redis:latest
    volumes:
      - redis_data:/data
    networks:
      - $PROJECT_NAME-network

  postgres:
    restart: always
    image: postgres:latest
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: root
      POSTGRES_PASSWORD: root
      POSTGRES_DB: $PROJECT_NAME
    ports:
      - "5432:5432"
    networks:
      - $PROJECT_NAME-network

  nginx:
    restart: always
    image: nginx:latest
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    links:
      - app:app
    ports:
      - "80:80"
      - "443:443"
    networks:
      - $PROJECT_NAME-network

  app:
    &app
    build: .
    restart: always
    volumes:
      - .:/code
    working_dir: /code
    ports:
      - "8080:8080"
    depends_on:
      - postgres
      - redis
    links:
      - postgres:postgres
      - redis:redis
    env_file:
      - .env.dev
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"
    command: >
      sh -c "python manage.py collectstatic --noinput &&
             python manage.py makemigrations &&
             python manage.py migrate &&
             python manage.py runserver 0.0.0.0:8080"

  worker:
    build: .
    command: celery -A $PROJECT_NAME worker --loglevel=info -c 4
    volumes:
      - .:/code
    depends_on:
      - postgres
      - redis
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  celerybeat:
    build: .
    restart: always
    command: celery -A $PROJECT_NAME beat -l info
    volumes:
      - .:/code
    depends_on:
      - postgres
      - redis
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  flower:
    build: .
    command: celery -A $PROJECT_NAME flower --port=5555
    ports:
      - "5555:5555"
    depends_on:
      - worker
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

networks:
  $PROJECT_NAME-network:

volumes:
  redis_data:
  postgres_data:

EOL

cat <<EOL > production.yml
services:
  redis:
    restart: always
    image: redis:latest
    volumes:
      - redis_data:/data
    networks:
      - $PROJECT_NAME-network

  postgres:
    restart: always
    image: postgres:latest
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: root
      POSTGRES_PASSWORD: root
      POSTGRES_DB: $PROJECT_NAME
    ports:
      - "5432:5432"
    networks:
      - $PROJECT_NAME-network

  nginx:
    restart: always
    image: nginx:latest
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    links:
      - app:app
    ports:
      - "80:80"
      - "443:443"
    networks:
      - $PROJECT_NAME-network

  app:
    &app
    build: .
    restart: always
    volumes:
      - .:/code
    working_dir: /code
    ports:
      - "8080:8080"
    depends_on:
      - postgres
      - redis
    links:
      - postgres:postgres
      - redis:redis
    env_file:
      - .env.dev
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"
    command: >
      sh -c "python manage.py collectstatic --noinput &&
             python manage.py makemigrations &&
             python manage.py migrate &&
             gunicorn $PROJECT_NAME.wsgi:application --bind 0.0.0.0:8080 -k gevent -w 4 -t 60"

  worker:
    build: .
    command: celery -A $PROJECT_NAME worker --loglevel=info -c 4
    volumes:
      - .:/code
    depends_on:
      - postgres
      - redis
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  celerybeat:
    build: .
    restart: always
    command: celery -A $PROJECT_NAME beat -l info
    volumes:
      - .:/code
    depends_on:
      - postgres
      - redis
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

  flower:
    build: .
    command: celery -A $PROJECT_NAME flower --port=5555
    ports:
      - "5555:5555"
    depends_on:
      - worker
    networks:
      - $PROJECT_NAME-network
    logging:
      driver: "json-file"
      options:
        max-size: "200k"
        max-file: "10"

networks:
  $PROJECT_NAME-network:

volumes:
  redis_data:
  postgres_data:

EOL

echo "Setting up environment variables..."
cat <<EOL > .env.dev
# Base Settings
SECRET_KEY=your_secret_key
DEBUG=True
DJANGO_ALLOWED_HOSTS=*
DJANGO_PROJECT_NAME=$PROJECT_NAME

# Database Settings
SQL_ENGINE=django.db.backends.postgresql
SQL_DATABASE=$PROJECT_NAME
SQL_USER=root
SQL_PASSWORD=root
SQL_HOST=postgres
SQL_PORT=5432

# Celery Settings
CELERY_BROKER_URL=redis://redis:6379/0
CELERY_RESULT_BACKEND=redis://redis:6379/0
EOL

cat <<EOL > .env.prod
# Base Settings
SECRET_KEY=your_secret_key
DEBUG=False
DJANGO_ALLOWED_HOSTS=production_host_ip
DJANGO_PROJECT_NAME=$PROJECT_NAME

# Database Settings
SQL_ENGINE=django.db.backends.postgresql
SQL_DATABASE=$PROJECT_NAME
SQL_USER=root
SQL_PASSWORD=root
SQL_HOST=postgres
SQL_PORT=5432

# Celery Settings
CELERY_BROKER_URL=redis://redis:6379/0
CELERY_RESULT_BACKEND=redis://redis:6379/0
EOL

echo "Adding dependencies..."
cat <<EOL > requirements.txt
celery
Django
django-admin-inline-paginator
django-admin-interface
django-admin-rangefilter
django-celery-beat
django-celery-results
django-cors-headers
django-import-export
django-oauth-toolkit
drf-api-tracking
drf-spectacular
djangorestframework
drf-api-tracking
drf-spectacular
flake8
flower
gevent
greenlet
gunicorn
ipython
kombu
pandas
psycopg2
pre-commit
python-dateutil
python-dotenv
redis
requests
segno
tzdata
unicodecsv
urllib3

EOL

echo "Creating multi-db router"
mkdir -p base

cat <<EOL > base/routers.py
from django.utils.module_loading import import_string


class GenericRouter(object):

    def _get_model(self, app_label, model_name):
        try:
            models = import_string('{}.models'.format(app_label))
            attrs = {i.lower(): i
                     for i in dir(models)
                     if not i.startswith('_')}

            return getattr(models, attrs.get(model_name), None)
        except Exception as e:
            return None

    def _get_binding(self, obj):
        return getattr(obj, '__bind_key__', 'default')

    def db_for_read(self, model, **hints):
        return self._get_binding(model)

    def db_for_write(self, model, **hints):
        return self._get_binding(model)

    def allow_relation(self, obj1, obj2, **hints):
        return self._get_binding(obj1) == self._get_binding(obj2)

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        binding = self._get_binding(self._get_model(app_label, model_name))
        return binding == 'default'

EOL

echo "Creating $APP_NAME user model..."
cat <<EOL > $APP_NAME/models.py
from django.contrib.auth.models import AbstractUser
from django.db import models

class CustomUser(AbstractUser):
    STATE_ACTIVE = 'active'
    STATE_INACTIVE = 'inactive'

    STATE_CHOICES = [
        ('active', 'active'),
        ('inactive', 'inactive')
    ]

    ROLE_CUSTOMER = 'customer'
    ROLE_ADMIN = 'admin'
    ROLE_MANAGER = 'manager'
    ROLE_CLERK = 'clerk'

    ROLE_CHOICES = [
        ('customer', 'customer'),
        ('admin', 'admin'),
        ('manager', 'manager'),
        ('clerk', 'clerk'),
    ]

    address_line_1 = models.CharField(max_length=100, null=True, blank=True)
    address_line_2 = models.CharField(max_length=100, null=True, blank=True)
    address_line_3 = models.CharField(max_length=100, null=True, blank=True)
    province = models.CharField(max_length=100, null=True, blank=True)
    city = models.CharField(max_length=100, null=True, blank=True)
    country = models.CharField(max_length=100, null=True, blank=True)
    postal_code = models.CharField(max_length=20, null=True, blank=True)
    phone = models.CharField(max_length=20, null=True, blank=True)
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default=ROLE_CUSTOMER)
    scope = models.TextField(null=True, blank=True)
    state = models.CharField(max_length=50, default=STATE_ACTIVE)
    created_at = models.DateTimeField(auto_now_add=True, null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True, null=True, blank=True)

EOL

cat <<EOL > $APP_NAME/admin.py
from django.contrib import admin
from .models import CustomUser
from django.contrib.auth.admin import UserAdmin

class CustomUserAdmin(admin.ModelAdmin):
    list_display = ('username', 'first_name', 'last_name', 'state')  # Customize the list display for CustomUser
    list_filter = ('role', 'state')  # Add list filters for CustomUser

admin.site.register(CustomUser, CustomUserAdmin)

EOL

echo "Creating Django ASGI application..."
cat <<EOL > $PROJECT_NAME/asgi.py
"""
ASGI config for $PROJECT_NAME project.

It exposes the ASGI callable as a module-level variable named \`\`application\`\`.

For more information on this file, see
https://docs.djangoproject.com/en/3.0/howto/deployment/asgi/
"""

import os
from django.core.asgi import get_asgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', '$PROJECT_NAME.settings')

application = get_asgi_application()
EOL

echo "Setting up Celery..."
cat <<EOL > $PROJECT_NAME/celery.py
from __future__ import absolute_import, unicode_literals
import os
from celery import Celery

os.environ.setdefault('DJANGO_SETTINGS_MODULE', '$PROJECT_NAME.settings')

app = Celery('$PROJECT_NAME')

app.config_from_object('django.conf:settings', namespace='CELERY')

app.autodiscover_tasks()
EOL

echo "Creating sample Celery task..."
cat <<EOL > $APP_NAME/tasks.py
from celery import shared_task

@shared_task
def add(x, y):
    return x + y
EOL

echo "Creating logs directory..."
mkdir -p logs

echo "Creating .gitignore file in the logs directory..."
echo "*" > logs/.gitignore

echo "Creating media directory..."
mkdir -p media

echo "Creating .gitignore file in the media directory..."
echo "*" > media/.gitignore

EOL

echo "Creating User CRUD with OAuth2 implementation..."
cat <<EOL > $APP_NAME/serializers.py
from rest_framework import serializers
from .models import CustomUser

class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = CustomUser
        fields = '__all__'

EOL

cat <<EOL > $APP_NAME/views.py
from rest_framework import generics, permissions, status
from rest_framework_tracking.mixins import LoggingMixin
from rest_framework.response import Response
from rest_framework.exceptions import NotFound
from drf_spectacular.utils import extend_schema
from drf_spectacular.utils import extend_schema
from .models import CustomUser
from .serializers import UserSerializer


class BaseViewMixin:
    permission_classes = [permissions.IsAuthenticated]


class UserListCreateView(LoggingMixin, BaseViewMixin, generics.ListCreateAPIView):
    queryset = CustomUser.objects.all()
    serializer_class = UserSerializer

    @extend_schema(description='List all users or create a new user',
                   request=UserSerializer,
                   responses={200: UserSerializer(many=True), 400: 'Bad Request'})
    def get(self, request, *args, **kwargs):
        return self.list(request, *args, **kwargs)

    @extend_schema(description='Create a new user',
                   request=UserSerializer,
                   responses={201: UserSerializer(), 400: 'Bad Request'})
    def post(self, request, *args, **kwargs):
        return self.create(request, *args, **kwargs)


class UserRetrieveUpdateDestroyView(LoggingMixin, BaseViewMixin, generics.RetrieveUpdateDestroyAPIView):
    queryset = CustomUser.objects.all()
    serializer_class = UserSerializer

    def handle_exception(self, exc):
        if isinstance(exc, NotFound):
            return Response({'error': 'User not found'}, status=status.HTTP_404_NOT_FOUND)
        return super().handle_exception(exc)

    @extend_schema(description='Retrieve a user by ID',
                   responses={200: UserSerializer(), 404: 'Not Found'})
    def get(self, request, *args, **kwargs):
        return self.retrieve(request, *args, **kwargs)

    @extend_schema(description='Update a user by ID',
                   request=UserSerializer,
                   responses={200: UserSerializer(), 400: 'Bad Request', 404: 'Not Found'})
    def put(self, request, *args, **kwargs):
        return self.update(request, *args, **kwargs)

    @extend_schema(description='Delete a user by ID',
                   responses={204: 'No Content', 404: 'Not Found'})
    def delete(self, request, *args, **kwargs):
        return self.destroy(request, *args, **kwargs)

EOL

cat <<EOL > $APP_NAME/urls.py
from django.urls import path
from .views import UserListCreateView, UserRetrieveUpdateDestroyView

urlpatterns = [
    path('users/', UserListCreateView.as_view(), name='user-list-create'),
    path('users/<int:pk>/', UserRetrieveUpdateDestroyView.as_view(), name='user-retrieve-update-destroy'),
]
EOL

echo "Updating project urls.py..."
cat <<EOL > $PROJECT_NAME/urls.py
from django.contrib import admin
from django.urls import path, include
from drf_spectacular.views import SpectacularAPIView, SpectacularRedocView, SpectacularSwaggerView
from django.conf import settings

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('app.urls')),
]

if settings.DEBUG:
    urlpatterns += [
        path('api/schema/',
             SpectacularAPIView.as_view(),
             name='api-schema'),
        path('api/docs/',
             SpectacularSwaggerView.as_view(url_name='api-schema'),
             name='api-docs'),
        path('api/redoc/',
             SpectacularRedocView.as_view(url_name='api-schema'),
             name='redoc'),
    ]

EOL

echo "Creating sample test for $APP_NAME user model..."
mkdir -p $APP_NAME/tests
cat <<EOL > $APP_NAME/tests/test_user.py
from django.test import TestCase
from django.contrib.auth import get_user_model

class CustomUserTests(TestCase):

    def test_create_user(self):
        User = get_user_model()
        user = User.objects.create_user(username='testuser', email='test@example.com', password='testpassword', address='123 Main St', mobile_number='1234567890')
        self.assertEqual(user.username, 'testuser')
        self.assertEqual(user.email, 'test@example.com')
        self.assertEqual(user.address, '123 Main St')
        self.assertEqual(user.mobile_number, '1234567890')
        self.assertTrue(user.check_password('testpassword'))

    def test_create_superuser(self):
        User = get_user_model()
        admin_user = User.objects.create_superuser(username='admin', email='admin@example.com', password='adminpassword', address='Admin St', mobile_number='0987654321')
        self.assertEqual(admin_user.username, 'admin')
        self.assertEqual(admin_user.email, 'admin@example.com')
        self.assertEqual(admin_user.address, 'Admin St')
        self.assertEqual(admin_user.mobile_number, '0987654321')
        self.assertTrue(admin_user.is_superuser)
        self.assertTrue(admin_user.is_staff)

EOL

echo "Creating README.md..."
cat <<EOL > README.md
# Django Project

This is a sample Django project with Docker setup.

## Setup

1. Make sure Docker Desktop is running.
2. Navigate to the project directory.
3. Run the following command to set up the project:
    \`\`\`
    ./setup.sh $PROJECT_NAME $APP_NAME
    \`\`\`

## Usage

1. Start the Docker containers:
    \`\`\`
    docker-compose up
    \`\`\`
2. Open your browser and navigate to \`http://localhost:8080\`.

## API Endpoints

- \`/api/users/\`: List and create users.
- \`/api/users/<id>/\`: Retrieve, update, and delete users.

## Monitoring

- Access the Celery Flower monitoring tool at: \`http://localhost:5555\`.
- View logs in real-time with Logstash by following the Docker container logs.

## Running Tests

1. Run the following command to execute the tests:
    \`\`\`
    docker-compose run app python manage.py test
    \`\`\`
EOL

echo "Setting up Docker..."
cat <<EOL > Dockerfile
# Use the official Python image from the Docker Hub
# Use the official Python image from the Docker Hub
FROM python:3.12

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

# Set work directory
WORKDIR /code

# Install dependencies
COPY requirements.txt /code/
RUN pip install --upgrade pip
RUN pip install -r requirements.txt

# Copy project
COPY . /code/
EOL

echo "Creating template directory..."
mkdir -p templates

rm $PROJECT_NAME/settings.py
cat <<EOL > $PROJECT_NAME/settings.py
"""
Django settings for $PROJECT_NAME project.

Generated by 'django-admin startproject' using Django 4.0.4.

For more information on this file, see
https://docs.djangoproject.com/en/4.0/topics/settings/

For the full list of settings and their values, see
https://docs.djangoproject.com/en/4.0/ref/settings/
"""

import os
from pathlib import Path
from dotenv import load_dotenv

# Build paths inside the project like this: BASE_DIR / 'subdir'.
BASE_DIR = Path(__file__).resolve().parent.parent

load_dotenv(dotenv_path=os.path.join(BASE_DIR, '.env.dev'))

# Quick-start development settings - unsuitable for production
# See https://docs.djangoproject.com/en/4.0/howto/deployment/checklist/

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = os.getenv('SECRET_KEY')

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = os.getenv('DEBUG', 'False') == 'True'

ALLOWED_HOSTS = os.getenv('DJANGO_ALLOWED_HOSTS').split(' ')

PROJECT_NAME = os.getenv('DJANGO_PROJECT_NAME')

# Application definition

INSTALLED_APPS = [
    'admin_interface',
    'colorfield',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'django_celery_beat',
    'django_celery_results',
    'django_admin_inline_paginator',
    'corsheaders',
    'import_export',
    'oauth2_provider',
    'drf_spectacular',
    'rest_framework',
    'rest_framework_tracking',
    '$APP_NAME',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = '{}.urls'.format(PROJECT_NAME)

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [
            os.path.join(BASE_DIR, 'templates/'),
        ],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = '{}.wsgi.application'.format(PROJECT_NAME)

# Database
# https://docs.djangoproject.com/en/4.0/ref/settings/#databases


# Password validation
# https://docs.djangoproject.com/en/4.0/ref/settings/#auth-password-validators

AUTH_PASSWORD_VALIDATORS = [
    {
        'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator',
    },
]


# Internationalization
# https://docs.djangoproject.com/en/4.0/topics/i18n/

LANGUAGE_CODE = 'en-us'

TIME_ZONE = 'Asia/Manila'

USE_I18N = True

USE_L10N = True

USE_TZ = True

# Static files (CSS, JavaScript, Images)
# https://docs.djangoproject.com/en/4.2/howto/static-files/

STATICFILES_DIRS = []

STATIC_ROOT = os.path.join(BASE_DIR, 'static')

STATIC_URL = '/static/'

# Media root
# https://docs.djangoproject.com/en/4.2/ref/settings/#media-root

MEDIA_ROOT = os.path.join(BASE_DIR, 'media')

MEDIA_URL = '/media/'

# Default primary key field type
# https://docs.djangoproject.com/en/4.2/ref/settings/#default-auto-field

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

DATA_UPLOAD_MAX_MEMORY_SIZE = 3 * 1024 * 1024  # 3 MB

DATABASE_ROUTERS = ['base.routers.GenericRouter']

DATABASES = {
    'default': {
        'ENGINE': os.environ.get('SQL_ENGINE'),
        'NAME': os.environ.get('SQL_DATABASE'),
        'USER': os.environ.get('SQL_USER'),
        'PASSWORD': os.environ.get('SQL_PASSWORD'),
        'HOST': os.environ.get('SQL_HOST'),
        'PORT': os.environ.get('SQL_PORT')
    }
}

for i in DATABASES.values():
    if i['ENGINE'] == 'django.db.backends.oracle':
        i['OPTIONS'] = {
            'threaded': True
        }

AUTH_USER_MODEL = '$APP_NAME.CustomUser'

REST_FRAMEWORK = {
    'DEFAULT_RENDERER_CLASSES': ['rest_framework.renderers.JSONRenderer'],
    'DEFAULT_SCHEMA_CLASS': 'drf_spectacular.openapi.AutoSchema',
}

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '[%(asctime)s] {%(pathname)s:%(lineno)d} %(levelname)s - %(message)s',
        },
    },
    'filters': {
        'require_debug_false': {
            '()': 'django.utils.log.RequireDebugFalse'
        },
        'require_debug_true': {
            '()': 'django.utils.log.RequireDebugTrue'
        },
    },
    'handlers': {
        'console': {
            'level': 'DEBUG',
            'filters': ['require_debug_true'],
            'class': 'logging.StreamHandler',
            'formatter': 'verbose'
        },
        'file': {
            'level': 'DEBUG',
            'class': 'logging.FileHandler',
            'filename': '/var/log/app/debug.log',
        },
    },
    'loggers': {
        '': {
            'handlers': ['console', 'file'],
            'level': 'DEBUG' if DEBUG else 'INFO',
            'propagate': True,
        },
    },
}

_log = {
    'default': {
        'level': 'DEBUG',
        'filters': ['require_debug_true'],
        'class': 'logging.handlers.TimedRotatingFileHandler',
        'filename': os.path.join(BASE_DIR, 'logs/debug.log'),
        'when': 'midnight',
        'formatter': 'verbose',
    },
    'info': {
        'level': 'INFO',
        'class': 'logging.handlers.TimedRotatingFileHandler',
        'filename': os.path.join(BASE_DIR, 'logs/info.log'),
        'when': 'midnight',
        'formatter': 'verbose',
    },
    'error': {
        'level': 'ERROR',
        'class': 'logging.handlers.TimedRotatingFileHandler',
        'filename': os.path.join(BASE_DIR, 'logs/error.log'),
        'when': 'midnight',
        'formatter': 'verbose',
    },
}

LOGGING['handlers'].update(_log)
LOGGING['loggers']['']['handlers'].extend(_log.keys())

# Celery Configuration
CELERY_BROKER_URL = os.getenv('CELERY_BROKER_URL', 'redis://redis:6379/0')

CELERY_RESULT_BACKEND = os.getenv('CELERY_RESULT_BACKEND', 'redis://redis:6379/0')

from kombu import Queue

CELERY_ENABLE_UTC = False

CELERY_TIMEZONE = "Asia/Manila"

BROKER_URL = os.environ.get('CELERY_BROKER_URL', '')

BROKER_TRANSPORT_OPTIONS = {'visibility_timeout': 7200} # 2 hours

CELERY_DEFAULT_QUEUE = 'default'

CELERY_QUEUES = (
    Queue('default', routing_key='config.instant'),
)

# CORS headers
# https://github.com/ottoyiu/django-cors-headers#configuration

CORS_ORIGIN_ALLOW_ALL = False

SPECTACULAR_SETTINGS = {
    'TITLE': PROJECT_NAME.title(),
    'VERSION': '1.0.0',
    'DESCRIPTION': PROJECT_NAME.title() + ' Open API Documentation',
    'COMPONENT_SPLIT_REQUEST': True,
}
EOL

echo "Starting services and and initial migration..."
docker-compose up -d

echo "Setup complete!"
