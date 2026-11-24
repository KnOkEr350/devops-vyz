from django import forms
from django.db import DatabaseError
from django.http import JsonResponse
from django.shortcuts import redirect, render
from django.views.decorators.http import require_GET, require_http_methods

from .models import Note


class NoteForm(forms.ModelForm):
    class Meta:
        model = Note
        fields = ["text"]
        labels = {"text": "Текст заметки"}


@require_http_methods(["GET", "POST"])
def index(request):
    form = NoteForm(request.POST if request.method == "POST" else None)
    if form.is_valid():
        form.save()
        return redirect("index")
    notes = Note.objects.order_by("-id")[:30]
    return render(request, "notes/index.html", {"form": form, "notes": notes})


@require_GET
def health(request):
    try:
        Note.objects.exists()
    except DatabaseError:
        return JsonResponse({"status": "unavailable", "database": "postgresql"}, status=503)
    return JsonResponse({"status": "ok", "database": "postgresql"})
