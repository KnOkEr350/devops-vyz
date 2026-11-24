from django.db import models


class Note(models.Model):
    text = models.CharField(max_length=180)
    created_at = models.DateTimeField(auto_now_add=True)
