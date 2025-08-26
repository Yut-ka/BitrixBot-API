# -*- coding: utf-8 -*-

APP_CONFIG = {
  'asd1a2s3d4asd41a23sdas4d': {
      'CLIENT_ID': '',
      'CLIENT_SECRET': ''
  }
}

def get_app_config(app_token):
    return APP_CONFIG.get(app_token) 