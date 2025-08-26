# -*- coding: utf-8 -*-

APP_CONFIG = {
  'd335b036050cccfdeb8beb1f72f7f0dc': {
      'CLIENT_ID': '',
      'CLIENT_SECRET': ''
  }
}

def get_app_config(app_token):
    return APP_CONFIG.get(app_token) 